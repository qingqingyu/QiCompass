"""MeteredAIClient:LLM 调用结果计数 + 失败率告警(2026-10-09 监控 A 档)。

包装任意 AIClient(anthropic/openai),interpret() 结束后记录:
- 成功 → (hour, provider, module, "success") +1
- AIProviderError → (hour, provider, module, e.reason) +1
  + llm_last_error 快照
- 其他异常 → outcome "unexpected" +1(client 层应已包完 AIProviderError,
  漏网即代码 bug;provider 可用性兜底同样计)

三类都**原样上抛,不改写不吞**(错误显式传播;监控只旁观)。

失败率告警:当前 UTC 小时桶内该 provider 调用总数 ≥ LLM_ALERT_MIN_CALLS
且失败率 ≥ LLM_ALERT_FAILURE_RATE → ERROR 级「ALERT llm_failure_rate」
标记日志(运维 grep / 日志平台 hook 该锚点;无外部推送通道是「不引入
新依赖」拍板的代价)。进程内每 provider 10 分钟节流;uvicorn 多 worker
各自独立节流(上限 = workers × 6 条/小时,日志量有界)。曾告警后转
健康 → INFO 级「ALERT_RESOLVED llm_failure_rate」(恢复不受 min_calls
下限遮蔽;流量停摆后无新调用时由 /api/health/llm 巡检顺带评估收尾)。

store 写失败只记 ERROR 日志、不反噬主路径(监控可用性不能以牺牲主请求
为代价;对齐 _refund_daily_quota 退款失败只记日志的先例)。

计数与告警评估在**后台任务**里做(2026-10-10 外评 #3):interpret() 返回
前不再等待 SQLite 写 + 聚合查询——store 短连接 timeout=5s,锁竞争时已经
成功的 LLM 响应最多被监控拖住 ~10s。后台化后订单仍保持「先 record 后
evaluate」(同一任务内串行),告警及时性不变;任务持强引用防 GC 中途丢弃,
`wait_for_pending_records()` 供测试 join 与优雅停机收尾。

计数口径与配额一致:只计真烧 LLM 的调用(缓存命中不进 client 天然
不计);module 维度由调用方经 interpret(module=...) 传入,None 计
"unknown"。
"""

from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone
from typing import Protocol

from ..config import LLM_ALERT_FAILURE_RATE, LLM_ALERT_MIN_CALLS
from ..errors import AIProviderError
from .store import LLMOutcomeStore, hour_key

logger = logging.getLogger(__name__)

# 同一 provider 两次 ALERT 的最小间隔(秒):失败率持续超阈时每 10 分钟
# 重申一次,而不是每次失败刷一行
_ALERT_REEMIT_SECONDS = 600.0
# 进程内告警状态:{provider: 上次 ALERT 发出时刻(monotonic)}。
# 只做节流与恢复检测,不做跨进程聚合(多 worker 独立,见模块 docstring)。
_last_alert_emit: dict[str, float] = {}

# 在飞后台计数任务注册表(强引用;完成即出集):fire-and-forget 任务只被
# 事件循环弱持有,不落强引用可能被 GC 中途丢弃(CPython asyncio 文档口径)。
_pending_records: set[asyncio.Task] = set()


async def wait_for_pending_records() -> None:
    """join 全部在飞计数/告警任务(测试确定性断言 + 优雅停机收尾用)。

    跨事件循环残留防御(2026-10-10 review):历史测试若 spawn 后未 join
    且其事件循环已关闭,done_callback 不会执行,task 残留本集合——不
    过滤会让下一个无关测试在 join 时抛 "attached to a different loop"
    (错位归因,难排查)。残留任务在发现时出集 + 记警告;忘 join 的测试
    自身断言(等 store 写完)仍会红,错误显式不错位。优雅停机路径下
    任务与本函数同 loop,行为不变。
    """
    current_loop = asyncio.get_running_loop()
    pending: list[asyncio.Task] = []
    for task in list(_pending_records):
        if task.done():
            _pending_records.discard(task)  # 幂等兜底(done_callback 已做)
            continue
        if task.get_loop() is not current_loop:
            logger.warning(
                "llm_metrics.record_task_orphaned_loop — 计数任务所属"
                "事件循环已关闭(测试 spawn 后未 join?),残留任务出集跳过")
            _pending_records.discard(task)
            continue
        pending.append(task)
    if pending:
        # return_exceptions(2026-10-10 第二十轮外评 #7):优雅停机窗口内个别
        # 记录任务被取消时,裸 gather 会把 CancelledError 抛进 lifespan
        # shutdown 钩子,其余仍在跑的记录随之不被 join——收尾要的是「等完
        # 所有还在跑的」,单个被取消不反噬整体(_record_observed 已自捕获
        # Exception,此处只补 CancelledError 这类 BaseException 的口子)。
        await asyncio.gather(*pending, return_exceptions=True)


class _InnerClient(Protocol):
    """MeteredAIClient 包装的最小 inner 契约(即 AIClient)。"""

    @property
    def provider(self) -> str: ...

    @property
    def model(self) -> str: ...

    async def interpret(
        self, prompt: str, *, temperature: float = 0.6,
        max_tokens: int | None = None, timeout: float | None = None,
        module: str | None = None,
    ) -> str: ...


class MeteredAIClient:
    """计数 + 告警旁观层;对外保持被包装 client 的完整协议(可再套)。"""

    def __init__(self, inner: _InnerClient, store: LLMOutcomeStore):
        self._inner = inner
        self._store = store

    @property
    def provider(self) -> str:
        return self._inner.provider

    @property
    def model(self) -> str:
        return self._inner.model

    async def interpret(
        self, prompt: str, *, temperature: float = 0.6,
        max_tokens: int | None = None,
        timeout: float | None = None,
        module: str | None = None,
    ) -> str:
        try:
            text = await self._inner.interpret(
                prompt, temperature=temperature, max_tokens=max_tokens,
                timeout=timeout, module=module)
        except AIProviderError as e:
            self._spawn_record(module, outcome=e.reason, message=e.message)
            raise
        except Exception as e:
            # client 层契约:一切 provider 侧故障已包成 AIProviderError。
            # 走到这里 = 包装修漏(代码 bug)或环境级意外——可用性兜底
            # 同样计数,异常本身原样上抛。
            self._spawn_record(
                module, outcome="unexpected",
                message=f"{type(e).__name__}: {e}")
            raise
        self._spawn_record(module, outcome="success")
        return text

    def _spawn_record(
        self, module: str | None, *, outcome: str, message: str | None = None,
    ) -> None:
        """计数 + 告警评估转后台任务(不阻塞 interpret 返回;见模块 docstring)。

        任务体内 `_record_observed` 已全捕获,异常不会外溢为
        "Task exception was never retrieved"。
        """
        task = asyncio.create_task(
            self._record_observed(module, outcome=outcome, message=message))
        _pending_records.add(task)
        task.add_done_callback(_pending_records.discard)

    async def _record_observed(
        self, module: str | None, *, outcome: str, message: str | None = None,
    ) -> None:
        try:
            await self._after_call(module, outcome=outcome, message=message)
        except Exception:
            # 理论不可达(_after_call/evaluate_alert 已自捕获);兜底防
            # 无人 await 的后台任务异常噪音
            logger.exception(
                "llm_metrics.record_task_failed provider=%s module=%s "
                "outcome=%s", self.provider, module, outcome)

    async def _after_call(self, module: str | None, *, outcome: str,
                          message: str | None = None) -> None:
        """计数 + 失败快照 + 告警评估;任何 store 故障只记日志。"""
        now = datetime.now(timezone.utc)
        hour = hour_key(now)
        module_key = module or "unknown"
        try:
            await asyncio.to_thread(
                self._store.record, hour=hour, provider=self.provider,
                module=module_key, outcome=outcome)
            if outcome != "success" and message is not None:
                await asyncio.to_thread(
                    self._store.record_last_error,
                    occurred_at=now.isoformat(), provider=self.provider,
                    module=module_key, reason=outcome, message=message)
        except Exception as e:
            logger.error(
                "llm_metrics.record_failed provider=%s module=%s "
                "outcome=%s error=%r",
                self.provider, module_key, outcome, e)
            return
        await asyncio.to_thread(self.evaluate_alert, hour)

    def evaluate_alert(self, hour: str) -> None:
        """当前小时桶失败率告警/恢复评估(同步核心;后台任务与 health
        巡检共用)。store 读失败只记日志,不外溢。

        恢复判据不受 min_calls 下限遮蔽(2026-10-10 review):告警发射
        仍要求 total ≥ min_calls(低流量不误报),但**恢复**只看「本进程
        曾告警过且当前不满足告警条件」——total < min_calls(跨整点新桶
        样本还少 / 流量已停)时提前 return 会让 ALERT_RESOLVED 永不落地,
        日志平台上这次故障一直挂「未恢复」。total=0 时 rate 取 0.0
        (除零防御,语义=不满足告警条件)。
        """
        try:
            counts = self._store.get_counts(start_hour=hour, end_hour=hour)
        except Exception as e:
            logger.error(
                "llm_metrics.alert_eval_failed provider=%s error=%r",
                self.provider, e)
            return
        total = sum(c for (p, _m, _o), c in counts.items()
                    if p == self.provider)
        failures = sum(c for (p, _m, o), c in counts.items()
                       if p == self.provider and o != "success")
        rate = failures / total if total else 0.0
        if (total >= LLM_ALERT_MIN_CALLS
                and rate >= LLM_ALERT_FAILURE_RATE):
            now_mono = time.monotonic()
            # 「从未告警」不节流:last 缺省若取 0.0,会把 monotonic 的基准点
            # (Linux/macOS = 开机时刻)误当第 0 秒告警过——机器开机不到
            # _ALERT_REEMIT_SECONDS 时**首次告警被吞**(服务器重启/刚部署
            # 恰是最需要告警的时刻)。None = 首告警直发(2026-10-10 外评 #1)。
            last_emit = _last_alert_emit.get(self.provider)
            if (last_emit is not None
                    and now_mono - last_emit < _ALERT_REEMIT_SECONDS):
                return
            _last_alert_emit[self.provider] = now_mono
            logger.error(
                "ALERT llm_failure_rate provider=%s window=hour:%s "
                "total=%d failures=%d rate=%.2f threshold=%.2f",
                self.provider, hour, total, failures, rate,
                LLM_ALERT_FAILURE_RATE)
        elif self.provider in _last_alert_emit:
            # 曾在本进程告警过,现不满足告警条件 → 恢复留痕(各 worker 独立,
            # 至少一个 worker 看到恢复即有日志锚点)
            _last_alert_emit.pop(self.provider, None)
            logger.info(
                "ALERT_RESOLVED llm_failure_rate provider=%s window=hour:%s "
                "total=%d failures=%d rate=%.2f",
                self.provider, hour, total, failures, rate)
