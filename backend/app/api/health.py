"""GET /api/health + GET /api/health/llm。"""

import re
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException, Request, Response

from ..ai.prompts import PROMPT_VERSIONS
from ..config import (
    LLM_ALERT_FAILURE_RATE,
    LLM_ALERT_MIN_CALLS,
    LLM_HEALTH_TOKEN,
    LUNAR_PYTHON_VERSION,
    MODEL_ID,
)
from ..monitoring.metered import MeteredAIClient
from ..monitoring.store import LLMOutcomeStore, hour_key

router = APIRouter()


@router.get("/api/health")
def health(request: Request, response: Response) -> dict:
    """返回运行中实际 AI client 身份;禁止 HTTP 缓存避免切换后读旧值。

    prompt_versions(2026-10-08 外评 #4):各 module 当前 PROMPT_VERSIONS 快照。
    iOS 读本地解读缓存前强校验 health(ADR-0009),顺带取得版本表——本地行
    只认服务端当前版本,封掉「prompt bump 只失效后端缓存,客户端 24h 内
    旧版行照常命中并写进新合盘快照」的客户端失防窗口。
    """
    ai_client = request.app.state.ai_client
    response.headers["Cache-Control"] = "no-store"
    return {
        "status": "ok",
        "lunar_python_version": LUNAR_PYTHON_VERSION,
        "model": MODEL_ID,
        "ai_provider": ai_client.provider,
        "ai_model": ai_client.model,
        "prompt_versions": dict(PROMPT_VERSIONS),
    }


def _aggregate(counts: dict, provider: str) -> dict:
    """{(provider, module, outcome): count} → 单 provider 窗口汇总。

    失败率 = 非 success 占比;total=0 时 rate=None(JSON null)——空窗口
    没有「0% 失败」的含义,别拿 0 误导运维。
    """
    total = success = 0
    failures: dict[str, int] = {}
    for (p, _m, outcome), c in counts.items():
        if p != provider:
            continue
        total += c
        if outcome == "success":
            success += c
        else:
            failures[outcome] = failures.get(outcome, 0) + c
    return {
        "success": success,
        "failures": failures,
        "total": total,
        "failure_rate": (round((total - success) / total, 4)
                         if total else None),
    }


def _by_module(counts: dict, provider: str) -> dict:
    """今日窗口按 module 拆分(定位「哪个模块在烧失败」)。"""
    modules: dict[str, dict] = {}
    for (p, module, outcome), c in counts.items():
        if p != provider:
            continue
        slot = modules.setdefault(
            module, {"success": 0, "failures": {}, "total": 0})
        slot["total"] += c
        if outcome == "success":
            slot["success"] += c
        else:
            slot["failures"][outcome] = \
                slot["failures"].get(outcome, 0) + c
    for slot in modules.values():
        slot["failure_rate"] = (
            round((slot["total"] - slot["success"]) / slot["total"], 4)
            if slot["total"] else None)
    return modules


def _authorize_llm_health(request: Request) -> None:
    """/api/health/llm 鉴权(2026-10-10 外评 #2,fail-closed)。

    - token 未配置 → 404:端点返回 provider 原始错误片段(llm_last_error
      .message,可能含中转地址/上游响应内容)与按模块调用量,属运维敏感
      信息——反代会转发全部路径,不配置就当端点不存在,不暴露存在性;
    - token 配置但 Authorization: Bearer 不匹配 → 401;
    - 比对走 secrets.compare_digest,防时序侧信道逐字节试探。
    """
    if not LLM_HEALTH_TOKEN:
        raise HTTPException(status_code=404, detail="Not Found")
    auth = request.headers.get("Authorization", "")
    # scheme 大小写不敏感(RFC 7235),解析对齐仓内既有 JWT 侧
    # (app/auth/dependencies.py 的 split + lower)——curl 小写 bearer
    # 在 JWT 端点可用、本端点却恒 401 的行为分叉不要。
    parts = auth.split(maxsplit=1)
    provided = (parts[1].strip()
                if len(parts) == 2 and parts[0].lower() == "bearer" else "")
    if not provided:
        raise HTTPException(status_code=401, detail="Unauthorized")
    # 非 ASCII bearer(经 latin-1 头解码可达)会让 compare_digest 抛
    # TypeError → 500;畸形输入只配 401(对齐 context_binding.verify_token
    # 的既有收口与回归测试,2026-10-07 review 实测同类)。
    try:
        matched = secrets.compare_digest(provided, LLM_HEALTH_TOKEN)
    except TypeError:
        matched = False
    if not matched:
        raise HTTPException(status_code=401, detail="Unauthorized")


@router.get("/api/health/llm")
def health_llm(request: Request, response: Response) -> dict:
    """LLM provider 可用性监控(2026-10-09 监控闭环 A 档,运维只读出口;
    2026-10-10 起须 Bearer QICOMPASS_LLM_HEALTH_TOKEN,未配置整体 404)。

    数据源 llm_metrics_store(MeteredAIClient 只计真烧 LLM 的调用;口径
    见 app/monitoring/metered.py docstring)。全部按**当前 provider** 过滤
    ——切换 provider 后旧 provider 的历史计数不再混入可用性判断。

    窗口(小时桶聚合,UTC):
    - current_hour:当前 UTC 小时桶(告警同一窗口;小时开头样本少,
      failure_rate 抖动大属正常,min_calls 下限在告警侧防误报)
    - last_24h:近 24 个小时桶(含当前)
    - today:UTC 当日

    alert.active 与 MeteredAIClient.evaluate_alert 同公式无状态重算
    (current_hour 总数 ≥ min_calls 且失败率 ≥ 阈值),与进程内告警日志
    互为印证;查询时顺带跑一次 evaluate_alert 收尾告警生命周期
    (见下方巡检注释)。
    """
    _authorize_llm_health(request)
    store: LLMOutcomeStore = request.app.state.llm_metrics_store
    ai_client = request.app.state.ai_client
    response.headers["Cache-Control"] = "no-store"

    now = datetime.now(timezone.utc)
    current = hour_key(now)

    # 巡检顺带评估告警/恢复(2026-10-10 review):恢复评估原本只挂在
    # 「新 LLM 调用落计数」之后,流量停摆或跨整点低流量时永不再跑,
    # ALERT_RESOLVED 一直缺位——运维查 health 恰是「有人在看监控」的
    # 在场证明,查询即收尾(各 worker 独立口径不变;store 读失败在
    # evaluate_alert 内自捕获,不反噬本端点。测试 stub 非 MeteredAIClient
    # 跳过)。
    if isinstance(ai_client, MeteredAIClient):
        ai_client.evaluate_alert(hour=current)

    start_24h = hour_key(now - timedelta(hours=23))
    today_start = f"{now.date().isoformat()}T00"

    counts_1h = store.get_counts(start_hour=current, end_hour=current)
    counts_24h = store.get_counts(start_hour=start_24h, end_hour=current)
    counts_today = store.get_counts(start_hour=today_start, end_hour=current)

    current_window = _aggregate(counts_1h, ai_client.provider)
    alert_active = (
        current_window["total"] >= LLM_ALERT_MIN_CALLS
        and current_window["failure_rate"] is not None
        and current_window["failure_rate"] >= LLM_ALERT_FAILURE_RATE
    )

    last_error = store.get_last_error()
    if last_error is not None and last_error["provider"] != ai_client.provider:
        # 与全端点口径一致:只看当前 provider(切换后旧 provider 的
        # 最近失败不再展示,避免误判当前可用性)
        last_error = None
    if last_error is not None:
        # URL 脱敏(2026-10-10):httpx 异常文本可能带上游 endpoint(如中转
        # 网关地址)——运维排障要 reason/类型,不需要具体 URL;出口层脱敏,
        # DB 存原文(health 之外的排障通道仍可见全量)。鉴权之外的第二道
        # 纵深:令牌一旦泄漏,中转拓扑不随之裸奔。
        # 任意 scheme(2026-10-10 review):代理错误文本可带 socks5:// 等
        # 非 http(s) 地址,https?:// 之外的都成漏网;凭证形态(user:pass@
        # host,URL 里已被上一条整段吞掉,此处兜无 scheme 的裸写)一并
        # 屏蔽——邮箱无「user:pass@」冒号段结构,不误伤。
        message = re.sub(r"[a-zA-Z][a-zA-Z0-9+.\-]*://\S+", "[url]",
                         last_error["message"])
        last_error["message"] = re.sub(
            r"[^\s/:?#]+:[^\s/@?#]+@[^\s]+", "[credentials@host]", message)

    return {
        "provider": ai_client.provider,
        "model": ai_client.model,
        "windows": {
            "current_hour": current_window,
            "last_24h": _aggregate(counts_24h, ai_client.provider),
            "today": _aggregate(counts_today, ai_client.provider),
        },
        "today_by_module": _by_module(counts_today, ai_client.provider),
        "last_error": last_error,
        "alert": {
            "active": alert_active,
            "failure_rate": current_window["failure_rate"],
            "window": "current_hour",
            "min_calls": LLM_ALERT_MIN_CALLS,
            "threshold": LLM_ALERT_FAILURE_RATE,
        },
    }
