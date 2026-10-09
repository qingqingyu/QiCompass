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
健康 → INFO 级「ALERT_RESOLVED llm_failure_rate」。

store 写失败只记 ERROR 日志、不反噬主路径(监控可用性不能以牺牲主请求
为代价;对齐 _refund_daily_quota 退款失败只记日志的先例)。

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
            await self._after_call(
                module, outcome=e.reason, message=e.message)
            raise
        except Exception as e:
            # client 层契约:一切 provider 侧故障已包成 AIProviderError。
            # 走到这里 = 包装修漏(代码 bug)或环境级意外——可用性兜底
            # 同样计数,异常本身原样上抛。
            await self._after_call(
                module, outcome="unexpected",
                message=f"{type(e).__name__}: {e}")
            raise
        await self._after_call(module, outcome="success")
        return text

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
        await self._evaluate_alert(hour)

    async def _evaluate_alert(self, hour: str) -> None:
        """当前小时桶失败率告警/恢复评估(仅本 provider 维度)。"""
        try:
            counts = await asyncio.to_thread(
                self._store.get_counts, start_hour=hour, end_hour=hour)
        except Exception as e:
            logger.error(
                "llm_metrics.alert_eval_failed provider=%s error=%r",
                self.provider, e)
            return
        total = sum(c for (p, _m, _o), c in counts.items()
                    if p == self.provider)
        if total < LLM_ALERT_MIN_CALLS:
            return
        failures = sum(c for (p, _m, o), c in counts.items()
                       if p == self.provider and o != "success")
        rate = failures / total
        if rate >= LLM_ALERT_FAILURE_RATE:
            now_mono = time.monotonic()
            if (now_mono - _last_alert_emit.get(self.provider, 0.0)
                    < _ALERT_REEMIT_SECONDS):
                return
            _last_alert_emit[self.provider] = now_mono
            logger.error(
                "ALERT llm_failure_rate provider=%s window=hour:%s "
                "total=%d failures=%d rate=%.2f threshold=%.2f",
                self.provider, hour, total, failures, rate,
                LLM_ALERT_FAILURE_RATE)
        elif self.provider in _last_alert_emit:
            # 曾在本进程告警过,现低于阈值 → 恢复留痕(各 worker 独立,
            # 至少一个 worker 看到恢复即有日志锚点)
            _last_alert_emit.pop(self.provider, None)
            logger.info(
                "ALERT_RESOLVED llm_failure_rate provider=%s window=hour:%s "
                "total=%d failures=%d rate=%.2f",
                self.provider, hour, total, failures, rate)
