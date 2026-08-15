"""QiCompass 宣传网站(promo-site)— 内部生成工具。

复用 backend/ 的 engine + ai client 模块(sys.path.insert),不走 HTTP 调用。
**绝不** import backend.app.config(JWT_SECRET_KEY 在 import 时会 raise)。

启动:
    cd tmp/promo-site
    pip install -r requirements.txt
    export ANTHROPIC_API_KEY=...   # 或 OPENAI_API_KEY
    export AI_PROVIDER=anthropic    # 或 openai
    uvicorn main:app --reload --port 8765

设计约束(DESIGN.md):
- 色板:#FDFCFA 极浅暖白 / #EBE3D0 卡片底 / #C33B3B 朱砂 CTA / #1C1C1C 浓墨文字
- 字体:Songti SC(标题/干支)+ PingFang SC(正文)+ SF Pro Text tabular-nums(数字)
- 8pt 基准网格;0.5pt hairline 分隔;无阴影/渐变/玻璃态
"""

from __future__ import annotations

import logging
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
import markdown as md
from markupsafe import Markup

# ---------- sys.path 注入 backend(仅一次,在任何 backend import 之前) ----------
_PROMO_ROOT = Path(__file__).resolve().parent
_BACKEND_ROOT = _PROMO_ROOT.parent.parent / "backend"
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

# ---------- JWT_SECRET_KEY 占位符(必须在任何 backend import 之前) ----------
# 原因:backend/app/config.py:127 在 import 时强制检查 JWT_SECRET_KEY,
# 而 app.ai.client → app.ai.anthropic_client 间接 import config。
# promo-site 不用 JWT(无用户系统),设一个 dev 占位符通过 import 守卫。
# 用户 shell 已设则不覆盖。
if not os.environ.get("JWT_SECRET_KEY"):
    os.environ["JWT_SECRET_KEY"] = "promo-site-dev-not-used"

from fastapi import FastAPI, Request  # noqa: E402
from fastapi.concurrency import run_in_threadpool  # noqa: E402
from fastapi.responses import HTMLResponse, JSONResponse  # noqa: E402
from fastapi.staticfiles import StaticFiles  # noqa: E402
from fastapi.templating import Jinja2Templates  # noqa: E402

# backend 模块复用(注意:不 import app.config,JWT_SECRET_KEY 会 raise)
from app.ai.client import create_ai_client  # noqa: E402
from app.ai.forbidden_words import validate_interpretation  # noqa: E402
from app.ai.prompts import PROMPT_VERSIONS  # noqa: E402
from app.engine.bazi_engine import BaziEngine  # noqa: E402
from app.engine.compatibility import compute_compatibility  # noqa: E402
from app.engine.daily_fortune import compute_daily_fortune  # noqa: E402
from app.engine.shensha import AUSPICIOUS  # noqa: E402  吉神 frozenset(11 个)
from app.models.compatibility import CompatibilityRequest  # noqa: E402
from app.models.daily_fortune import ChartPayload  # noqa: E402

from app.errors import (  # noqa: E402
    AIProviderError,
    BaziCalculationFailedError,
    InterpretationForbiddenError,
)

from context_builder import (  # noqa: E402
    build_bazi_context,
    build_compat_context,
    build_daily_context,
)

from v1_chain import (  # noqa: E402
    MODULE_META as V1_MODULE_META,
    V1UserInput,
    run_v1_chain,
)

from promo_prompts import (  # noqa: E402
    CHART_QA_MAX_OUTPUT_TOKENS,
    CHART_QA_TIMEOUT_SECONDS,
    LENGTH_TIERS,
    LENGTH_TIER_LABELS,
    LENGTH_TIER_PROMO,
    PROMO_MAX_OUTPUT_TOKENS,
    PROMO_TIMEOUT_SECONDS,
    render_chart_qa_prompt,
    render_prompt_with_length,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("promo-site")


# ---------- FastAPI app ----------

app = FastAPI(title="QiCompass Promo Site", version="0.1.0")

templates = Jinja2Templates(directory=str(_PROMO_ROOT / "templates"))
app.mount("/static", StaticFiles(directory=str(_PROMO_ROOT / "static")), name="static")


# ---------- 全量城市库(GeoNames cities500,2026-08-15) ----------
# data/cities.db 由 tools/build_city_db.py 生成(254k 行 / 235k 城市,含中文别名 +
# IANA 时区)。缺库不静默降级:搜索接口显式报错并给出构建指引。
# 连接策略:每请求独立只读连接(URI connect 微秒级)。不用全局连接——
# sqlite3 默认 check_same_thread=True,跨线程复用会 ProgrammingError(踩过)。

_CITY_DB_PATH = _PROMO_ROOT / "data" / "cities.db"


def _search_cities(like: str) -> list[sqlite3.Row]:
    """城市模糊搜索(在调用线程内执行,conn 用完即关,线程安全)。"""
    if not _CITY_DB_PATH.exists():
        raise FileNotFoundError(
            f"城市库缺失:{_CITY_DB_PATH}"
            "(构建方式见 tools/build_city_db.py 文件头注释)")
    conn = sqlite3.connect(f"file:{_CITY_DB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(
            """SELECT name_zh, name, lat, lng, country, admin1, population, tz
               FROM cities
               WHERE name_zh LIKE ? OR name LIKE ?
               ORDER BY population DESC
               LIMIT 20""",
            (like, like),
        ).fetchall()
    finally:
        conn.close()


@app.get("/geo/search")
async def geo_search(q: str = ""):
    """城市搜索(中文别名 / 拼音 / 英文名模糊匹配,人口优先,top 20)。

    sqlite LIKE 全表扫 25 万行是同步 CPU 活,按项目规则丢线程池,不阻塞 event loop。
    """
    query = q.strip()
    if not query:
        return JSONResponse({"error": "q 不能为空"}, status_code=400)
    try:
        rows = await run_in_threadpool(_search_cities, f"%{query}%")
    except FileNotFoundError as e:
        return JSONResponse({"error": str(e)}, status_code=500)
    return {
        "q": query,
        "results": [
            {"zh": r["name_zh"], "name": r["name"], "lat": r["lat"],
             "lng": r["lng"], "country": r["country"], "admin1": r["admin1"],
             "population": r["population"], "tz": r["tz"]}
            for r in rows
        ],
    }


@app.get("/geo/tz_offset")
async def geo_tz_offset(tz: str, dt: str):
    """出生时刻的精确 UTC 偏移(按 IANA 历史规则,含 1986-1991 中国夏令时)。

    dt 是"当地钟面时刻"(YYYY-MM-DDTHH:MM,无 tzinfo);
    偏移 = 该地区该钟面时刻的真实规则(夏令时期间自动 +1)。
    DST 切换瞬间的 fold 歧义取 fold=0(误差至多 1h,极边缘,注释留档)。
    """
    tz_name = tz.strip()
    if not tz_name:
        return JSONResponse({"error": "tz 不能为空"}, status_code=400)
    try:
        zone = ZoneInfo(tz_name)
    except (ZoneInfoNotFoundError, ValueError) as e:
        return JSONResponse(
            {"error": f"未知 IANA 时区: {tz_name!r}({e})"}, status_code=400,
        )
    if not dt.strip():
        return JSONResponse(
            {"error": "dt 不能为空(YYYY-MM-DDTHH:MM)"}, status_code=400)
    try:
        naive = datetime.fromisoformat(dt.strip())
    except ValueError as e:
        return JSONResponse(
            {"error": f"dt 解析失败: {e}(期望 YYYY-MM-DDTHH:MM)"}, status_code=400,
        )
    aware = naive.replace(tzinfo=zone)
    offset_h = aware.utcoffset().total_seconds() / 3600
    dst = aware.dst()
    return {
        "tz": tz_name,
        "offset_hours": offset_h,
        "is_dst": bool(dst) if dst is not None else False,
    }


# ---------- Jinja 过滤器 ----------

def _md_filter(text: Any) -> Markup:
    """markdown → HTML(Jinja 安全标记,免 autoescape)。

    v1 结果页 module 文本(LLM 输出)含 **粗体** 等 markdown 语法,
    模板 `{{ value | md }}` 渲染;null-ish 值渲染成空串。
    """
    if text is None:
        return Markup("")
    return Markup(_render_markdown_to_html(str(text)))


templates.env.filters["md"] = _md_filter


# ---------- AI client(启动时构造;key 缺失也构造,调用时显式报错) ----------

_ai_client = create_ai_client(
    provider=os.environ.get("AI_PROVIDER", "anthropic"),
    anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY"),
    anthropic_model=os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-6"),
    openai_api_key=os.environ.get("OPENAI_API_KEY"),
    openai_model=os.environ.get("OPENAI_MODEL", "gpt-4o"),
    openai_base_url=os.environ.get(
        "OPENAI_BASE_URL", "https://api.openai.com/v1"
    ),
)


def _get_client_for_request(form) -> tuple[Any, str, str]:
    """按表单提交的 AI 配置选 client(网页填 key 优先,fallback 到 env)。

    用户决策(2026-08-13):网页上填 provider/api_key/base_url/model(可选),
    没填则 fallback 到启动时构造的 _ai_client(env key)。

    Returns:
        (client, provider_str, model_str) — 给模板展示用
    """
    api_key = (form.get("ai_api_key") or "").strip()
    if not api_key:
        # fallback:用启动时构造的 client(env key)
        return _ai_client, _ai_client.provider, _ai_client.model

    # 网页填了 key → 临时构造 client(覆盖 env)
    provider = (form.get("ai_provider") or "anthropic").strip().lower()
    base_url = (form.get("ai_base_url") or "").strip()
    model = (form.get("ai_model") or "").strip()

    if provider == "anthropic":
        anthropic_model = model or "claude-sonnet-4-6"
        # base_url 透传(Anthropic 协议中转,如 z.ai /api/anthropic);不填走官方
        return (
            create_ai_client(
                provider="anthropic",
                anthropic_api_key=api_key,
                anthropic_model=anthropic_model,
                openai_api_key=None,
                openai_model="gpt-4o",
                anthropic_base_url=base_url or None,
            ),
            "anthropic",
            anthropic_model,
        )
    elif provider == "openai":
        openai_model = model or "gpt-4o"
        openai_base_url = base_url or "https://api.openai.com/v1"
        return (
            create_ai_client(
                provider="openai",
                anthropic_api_key=None,
                anthropic_model="claude-sonnet-4-6",
                openai_api_key=api_key,
                openai_model=openai_model,
                openai_base_url=openai_base_url,
            ),
            "openai",
            openai_model,
        )
    else:
        raise ValueError(f"未知 ai_provider: {provider}(必须 anthropic 或 openai)")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """首页:三模块入口卡片。"""
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "ai_provider": _ai_client.provider,
            "ai_model": _ai_client.model,
        },
    )


@app.get("/health")
async def health():
    """健康检查 + 配置自检。"""
    return {
        "status": "ok",
        "ai_provider": _ai_client.provider,
        "ai_model": _ai_client.model,
        "backend_root": str(_BACKEND_ROOT),
    }


# AI 连通性探针超时(秒):探针 max_tokens=1,15s 覆盖连接+首 token 绰绰有余;
# 比正式解读的 AI_TIMEOUT_SECONDS 短,避免用户等一个死连接等太久。
_AI_TEST_TIMEOUT = httpx.Timeout(15.0)


@app.post("/ai/test")
async def ai_test(request: Request):
    """AI 配置连通性探针:向 LLM endpoint 发一次 max_tokens=1 的真实 ping。

    验证四件事:URL 通不通 / key 有效无效 / model 名对不对 / 有没有被限流。
    key 来源口径与 _get_client_for_request 一致:表单填了用表单,没填 fallback 环境变量。

    返回 200 + {ok: false, error}:探针失败是业务结果不是服务端错误,
    错误文本直接展示给用户(错误显式传播,不吞)。
    """
    form = await request.form()
    provider = (form.get("ai_provider") or "").strip().lower()
    api_key = (form.get("ai_api_key") or "").strip()
    base_url = (form.get("ai_base_url") or "").strip()
    model = (form.get("ai_model") or "").strip()

    if provider not in ("anthropic", "openai"):
        return JSONResponse(
            {"ok": False, "error": f"未知 ai_provider:{provider!r}(必须 anthropic 或 openai)"},
        )

    key_source = "form"
    if not api_key:
        env_name = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
        api_key = os.environ.get(env_name) or ""
        key_source = "env"
    if not api_key:
        return JSONResponse(
            {"ok": False,
             "error": "API key 未填,环境变量也没有"
                      f"(export {env_name}=... 后重启,或在表单里填 key)"},
        )

    if provider == "anthropic":
        # 对齐 AnthropicClient:base_url 可选(Anthropic 协议中转),不填走官方
        base = (base_url or "https://api.anthropic.com").rstrip("/")
        url = f"{base}/v1/messages"
        model = model or "claude-sonnet-4-6"
        headers = {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
    else:
        base = (base_url or "https://api.openai.com/v1").rstrip("/")
        url = f"{base}/chat/completions"
        model = model or "gpt-4o"
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
    payload = {
        "model": model,
        "max_tokens": 1,
        "temperature": 0,
        "messages": [{"role": "user", "content": "ping"}],
    }

    start = time.perf_counter()
    try:
        # trust_env=False 对齐 OpenAIClient:本地代理(Clash 等)TLS-in-TLS
        # 隧道会造成假失败,探针必须绕开用户级代理才反映真实连通性。
        async with httpx.AsyncClient(timeout=_AI_TEST_TIMEOUT, trust_env=False) as client:
            resp = await client.post(url, headers=headers, json=payload)
        latency_ms = round((time.perf_counter() - start) * 1000)
    except httpx.TimeoutException as e:
        return JSONResponse(
            {"ok": False,
             "error": f"超时(15s 内无响应,{type(e).__name__})— "
                      "URL 不通或该 endpoint 需要代理"},
        )
    except httpx.RequestError as e:
        return JSONResponse(
            {"ok": False,
             "error": f"连接失败({type(e).__name__}):{e} — "
                      "检查 Base URL 拼写 / DNS / 网络"},
        )

    if resp.status_code == 401:
        return JSONResponse({"ok": False, "error": "HTTP 401 — API key 无效或未授权"})
    if resp.status_code == 403:
        return JSONResponse(
            {"ok": False,
             "error": "HTTP 403 — key 无权限,或请求地区被拒"
                      "(Anthropic 对部分地区直接回 403 Request not allowed,"
                      "官方 endpoint 需代理;中转 endpoint 则检查 key 是否开通该模型)"},
        )
    if resp.status_code == 404:
        return JSONResponse(
            {"ok": False,
             "error": "HTTP 404 — Base URL 或 model 名不对"
                      "(OpenAI 系检查路径是否以 /v1 结尾)"},
        )
    if resp.status_code == 429:
        return JSONResponse(
            {"ok": False, "error": "HTTP 429 — 限流(key 额度或频率受限)"},
        )
    if resp.status_code >= 400:
        # 其他 4xx/5xx:带响应体片段,便于第三方网关(clawto.link 等)排查
        return JSONResponse(
            {"ok": False, "error": f"HTTP {resp.status_code}:{resp.text[:200]}"},
        )

    return JSONResponse({
        "ok": True,
        "provider": provider,
        "model": model,
        "key_source": key_source,
        "latency_ms": latency_ms,
    })


# ---------- 深度解析(阶段 2) ----------

# element 英文 → 中文(与 spike run_spike.py:61 _ELEMENT_ZH 对齐)
_ELEMENT_ZH = {"wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水"}

_STRENGTH_LABEL_ZH = {
    "strong": "偏旺",
    "weak": "偏弱",
    "balanced": "中和",
    "special_pattern": "呈现从格特征",
}


def _render_markdown_to_html(text: str) -> str:
    """markdown 文本 → 安全 HTML(extensions 选用 nl2br + 标题/列表/引用基础语法)。

    不引入 bleach / nh3(避免新依赖);AI 输出已过 forbidden_words 校验,
    且 LLM 模板严格约束输出格式(不会主动产 <script>),HTML 注入风险可接受。
    若后续要更严格,引入 nh3 (~1MB pure Python)。
    """
    return md.markdown(
        text,
        extensions=["nl2br", "tables", "fenced_code"],
        output_format="html5",
    )


def _parse_birth_from_form(form) -> tuple[datetime, str, float]:
    """从表单数据构造 birth datetime / gender / longitude。

    表单字段:birth_date(YYYY-MM-DD)/ birth_time(HH:MM)/ tz_offset(整数小时) /
            gender(male/female) / longitude(float)
    """
    birth_date_str = form.get("birth_date")
    birth_time_str = form.get("birth_time")
    tz_offset_str = form.get("tz_offset", "8")
    gender = form.get("gender", "male")
    longitude_str = form.get("longitude", "116.4074")

    if not birth_date_str or not birth_time_str:
        raise ValueError("birth_date 和 birth_time 必填")

    # 拼成 naive datetime 然后附 tz_offset(timedelta)
    naive = datetime.fromisoformat(f"{birth_date_str}T{birth_time_str}:00")
    tz = timezone(timedelta(hours=int(tz_offset_str)))
    birth = naive.replace(tzinfo=tz)
    return birth, gender, float(longitude_str)


def _parse_length_tier(form) -> str:
    """解析篇幅档表单字段(默认加长版 — promo 物料是本工具主用途)。

    非法值显式抛 ValueError(由各 handler 的表单 try 捕获 → 400 页),
    不静默纠正。
    """
    tier = (form.get("length_tier") or "promo").strip().lower()
    if tier not in LENGTH_TIERS:
        raise ValueError(f"未知 length_tier:{tier!r}(必须 promo 或 app)")
    return tier


async def _interpret_with_tier(client: Any, prompt: str, length_tier: str) -> str:
    """按篇幅档调 AI:加长版放大 max_tokens + 超时,App 标准走 config 默认。

    加长版每章 1000-1500 字(付费 6 章总 6000-9000 字),config 默认
    1024 token / 90s 必然截断/超时,故 promo 档单独放大。
    """
    if length_tier == LENGTH_TIER_PROMO:
        return await client.interpret(
            prompt, temperature=0.6,
            max_tokens=PROMO_MAX_OUTPUT_TOKENS,
            timeout=PROMO_TIMEOUT_SECONDS,
        )
    return await client.interpret(prompt, temperature=0.6)


@app.get("/bazi", response_class=HTMLResponse)
async def bazi_form(request: Request):
    """深度解析输入表单。"""
    return templates.TemplateResponse(
        "bazi_form.html",
        {"request": request},
    )


def _prepare_chart_for_template(chart: dict) -> None:
    """给 chart dict 加模板需要的派生字段(in-place 修改,对齐 iOS 模板字段)。

    - 每柱补 gan_element_zh / zhi_element_zh / hide_gan_with_shishen(藏干 zip 十神)
    - shensha 分吉/凶两组(对齐 backend AUSPICIOUS frozenset)
    - element_balance 总数(供条形图算百分比)
    - strength_label / favorable_zh / unfavorable_zh 中文映射
    """
    # 1. 每柱补中文五行 + 藏干 zip 十神
    for pos in ('year', 'month', 'day', 'hour'):
        p = chart['pillars'][pos]
        p['gan_element_zh'] = _ELEMENT_ZH.get(p['gan_element'], '?')
        p['zhi_element_zh'] = _ELEMENT_ZH.get(p['zhi_element'], '?')
        # 藏干 zip 十神(过滤空值,日主柱可能特殊)
        hide_gan = p.get('hide_gan', []) or []
        shishen_zhi = p.get('shishen_zhi', []) or []
        p['hide_gan_with_shishen'] = list(zip(hide_gan, shishen_zhi))

    # 2. 神煞分组(对齐 backend AUSPICIOUS frozenset,11 吉 + 9 凶)
    ji, xiong = [], []
    for s in chart.get('shensha', []):
        (ji if s['name'] in AUSPICIOUS else xiong).append(s)
    chart['shensha_ji'] = ji
    chart['shensha_xiong'] = xiong

    # 3. 五行总数(供条形图百分比)
    eb = chart['element_balance']
    chart['element_total'] = sum(eb.values()) or 1  # 防 0 除

    # 4. 中文映射
    chart['strength_label'] = _STRENGTH_LABEL_ZH.get(
        chart['day_master_strength'], chart['day_master_strength'],
    )
    chart['favorable_zh'] = '、'.join(
        _ELEMENT_ZH.get(e, e) for e in chart['favorable_elements']
    ) or '—'
    chart['unfavorable_zh'] = '、'.join(
        _ELEMENT_ZH.get(e, e) for e in chart['unfavorable_elements']
    ) or '—'

    # 5. 出生信息格式化(供 chart-header 显示)
    birth_dt = chart.get('true_solar_time')
    if birth_dt:
        chart['true_solar_time_str'] = birth_dt.strftime('%Y-%m-%d %H:%M')


@app.post("/bazi", response_class=HTMLResponse)
async def bazi_handler(request: Request):
    """深度解析主流程:出生信息 → BaziEngine → render_prompt → AI → markdown。

    错误显式传播:engine 失败 / AI 失败 / 禁词命中 都显式渲染到结果页,
    不静默吞。日志记录全部细节。
    """
    form = await request.form()
    try:
        birth, gender, longitude = _parse_birth_from_form(form)
        length_tier = _parse_length_tier(form)
    except (ValueError, TypeError) as e:
        logger.warning("bazi.form_parse_failed error=%s", e)
        return templates.TemplateResponse(
            "bazi_result.html",
            _form_error_ctx(request, e, "/bazi"),
            status_code=400,
        )

    try:
        # ① engine 排盘(CPU-bound,放线程池)
        engine = BaziEngine()
        chart = await run_in_threadpool(
            engine.calculate,
            birth=birth,
            gender=gender,
            longitude=longitude,
            zi_hour_rule="zi_next_day",  # 产品默认(对齐 CLAUDE.md "强制 setSect(1)")
        )

        # ② 拍平成 prompt context(转调 spike builder)
        city = form.get("city") or None  # 手动经度模式下为 None
        context = build_bazi_context(chart, birth, gender, longitude, city=city)

        # ③ 渲染 prompt + 调 AI(网页填 key 优先,fallback env)
        client, _used_provider, _used_model = _get_client_for_request(form)
        module_tier = (form.get("module_tier") or "paid").strip().lower()
        if module_tier not in {"paid", "free"}:
            module_tier = "paid"
        module = f"bazi_deep_{module_tier}"
        # 现实对照变体(2026-08-15 方案 A+C):付费+加长版 且 填了现状 → 第七阶段
        reality = (form.get("reality_summary") or "").strip()
        if reality and module == "bazi_deep_paid" and length_tier == LENGTH_TIER_PROMO:
            module = "bazi_deep_paid_reality"
            context["reality_summary"] = reality
        prompt = render_prompt_with_length(module, context, length_tier)
        markdown_text = await _interpret_with_tier(client, prompt, length_tier)

        # ④ 禁词校验(强制:promo 物料上公开平台,命中即 raise)
        validate_interpretation(markdown_text)

        # ⑤ 给模板加派生字段(中文映射 + 神煞分组 + 五行总数 + 藏干 zip)
        _prepare_chart_for_template(chart)

        logger.info(
            "bazi.ok content_hash=%s day_master=%s strength=%s",
            chart["content_hash"], chart["pillars"]["day"]["gan"], chart["day_master_strength"],
        )

        return templates.TemplateResponse(
            "bazi_result.html",
            {
                "request": request,
                "chart": chart,
                "gender": gender,
                "markdown_html": _render_markdown_to_html(markdown_text),
                "markdown_text": markdown_text,
                "module_name": module,
                "length_label": LENGTH_TIER_LABELS[length_tier],
                "ai_provider": client.provider,
                "ai_model": client.model,
                "prompt_version": PROMPT_VERSIONS[module],
            },
        )

    except BaziCalculationFailedError as e:
        logger.error("bazi.engine_failed content_hash=%s error=%s", getattr(e, "content_hash", "?"), e)
        return templates.TemplateResponse(
            "bazi_result.html",
            _engine_error_ctx(request, e),
            status_code=500,
        )
    except AIProviderError as e:
        logger.error("bazi.ai_failed error=%s", e)
        return templates.TemplateResponse(
            "bazi_result.html",
            _ai_error_ctx(request, e),
            status_code=503,
        )
    except InterpretationForbiddenError as e:
        logger.warning("bazi.forbidden_words_hit error=%s", e)
        return templates.TemplateResponse(
            "bazi_result.html",
            _forbidden_error_ctx(request, e),
            status_code=422,
        )


# ---------- 错误上下文 helper(三模块共用) ----------

_HINTS = {
    "engine": "排查方向:① 出生时间是否合理(年份 1900+、月日时分合法);② 经度范围 -180~180;③ 时间是否在子时边界(23:00-01:00)。",
    "ai_provider": "排查方向:① <code>export ANTHROPIC_API_KEY=sk-ant-...</code> 或 <code>export OPENAI_API_KEY=sk-...</code>(二选一,与 <code>AI_PROVIDER</code> 对齐);② key 余额/有效性;③ 网络(国内访问 Anthropic/OpenAI 需代理)。",
    "forbidden": "AI 输出命中绝对化用语(必成 / 注定 / 一定 等)。处理:① 在表单里换一组出生信息重试;② 若反复命中,可能 prompt 模板有问题,需在 <code>backend/app/ai/prompts.py</code> 强化约束。",
}


def _form_error_ctx(request: Request, e: Exception, back_url: str = "/bazi") -> dict:
    return {
        "request": request,
        "error": f"表单解析失败:{e}",
        "error_type": "表单错误",
        "error_hint": "排查方向:① 出生日期 / 时间字段格式(YYYY-MM-DD + HH:MM);② 经度数值范围 -180 ~ 180;③ 时区整数(-12 ~ 14)。",
        "back_url": back_url,
    }


def _engine_error_ctx(request: Request, e: Exception, back_url: str = "/bazi") -> dict:
    return {
        "request": request,
        "error": f"排盘失败:{e}",
        "error_type": "排盘失败",
        "error_hint": _HINTS["engine"],
        "back_url": back_url,
    }


def _ai_error_ctx(request: Request, e: Exception, back_url: str = "/bazi") -> dict:
    return {
        "request": request,
        "error": f"AI 调用失败:{e}",
        "error_type": "AI 调用失败",
        "error_hint": _HINTS["ai_provider"],
        "back_url": back_url,
    }


def _forbidden_error_ctx(request: Request, e: Exception, back_url: str = "/bazi") -> dict:
    return {
        "request": request,
        "error": f"禁词拦截:{e}",
        "error_type": "禁词拦截",
        "error_hint": _HINTS["forbidden"],
        "back_url": back_url,
    }


# ---------- 合盘(阶段 3) ----------

def _chart_dict_to_payload(chart: dict) -> ChartPayload:
    """从 BaziEngine.calculate() dict 构造 ChartPayload(供 compatibility / daily_fortune 用)。

    BaziEngine 返回 dict 字段对齐 ChartPayload schema( Pydantic 自动验证)。
    four_pillars 需要手动提炼成 {pos: PillarRef(gan, zhi)}。
    """
    p = chart["pillars"]
    return ChartPayload(
        day_master=p["day"]["gan"],
        day_master_element=p["day"]["gan_element"],
        day_master_strength=chart["day_master_strength"],
        favorable_elements=chart["favorable_elements"],
        unfavorable_elements=chart["unfavorable_elements"],
        four_pillars={
            pos: {"gan": p[pos]["gan"], "zhi": p[pos]["zhi"]}
            for pos in ("year", "month", "day", "hour")
        },
        luck_pillars=chart["luck_pillars"],  # model_validate 自动转 list[LuckPillar]
        calc_rule_snapshot=chart.get("calc_rule_snapshot"),
    )


@app.get("/compat", response_class=HTMLResponse)
async def compat_form(request: Request):
    """合盘输入表单(两人)。"""
    return templates.TemplateResponse(
        "compat_form.html",
        {"request": request},
    )


@app.post("/compat", response_class=HTMLResponse)
async def compat_handler(request: Request):
    """合盘主流程:两人出生信息 → BaziEngine × 2 → compute_compatibility → AI → markdown。"""
    form = await request.form()
    try:
        birth_a, gender_a, longitude_a = _parse_birth_from_form_with_prefix(form, "a")
        birth_b, gender_b, longitude_b = _parse_birth_from_form_with_prefix(form, "b")
        context_label_key = form.get("context_label", "general")
        length_tier = _parse_length_tier(form)
    except (ValueError, TypeError) as e:
        logger.warning("compat.form_parse_failed error=%s", e)
        return templates.TemplateResponse(
            "compat_result.html",
            _form_error_ctx(request, e, "/compat"),
            status_code=400,
        )

    try:
        # ① 跑两人排盘(并行线程池)
        engine = BaziEngine()
        chart_a, chart_b = await run_in_threadpool(
            _calculate_two_charts,
            engine, birth_a, gender_a, longitude_a,
            birth_b, gender_b, longitude_b,
        )

        # ② 构造 CompatibilityRequest(模式 A:两人 hash + payload)
        compat_req = CompatibilityRequest(
            person_a_hash=chart_a["content_hash"],
            person_b_hash=chart_b["content_hash"],
            chart_payload_a=_chart_dict_to_payload(chart_a),
            chart_payload_b=_chart_dict_to_payload(chart_b),
            context=context_label_key,
        )
        compat_resp = await run_in_threadpool(compute_compatibility, req=compat_req)

        # ③ 渲染 prompt + 调 AI(网页填 key 优先,fallback env)
        client, _used_provider, _used_model = _get_client_for_request(form)
        module_tier = (form.get("module_tier") or "paid").strip().lower()
        if module_tier not in {"paid", "free"}:
            module_tier = "paid"
        module = f"compatibility_{module_tier}"
        city_a = form.get("city_a") or None
        city_b = form.get("city_b") or None
        context = build_compat_context(
            chart_a, chart_b, compat_resp,
            birth_a, birth_b,
            gender_a, gender_b,
            longitude_a, longitude_b,
            context_label_key=context_label_key,
            city_a=city_a, city_b=city_b,
        )
        prompt = render_prompt_with_length(module, context, length_tier)
        markdown_text = await _interpret_with_tier(client, prompt, length_tier)

        # ④ 禁词校验
        validate_interpretation(markdown_text)

        # 给两人 chart 加派生字段(供模板对齐 iOS DualPillarsTable)
        _prepare_chart_for_template(chart_a)
        _prepare_chart_for_template(chart_b)

        logger.info(
            "compat.ok hash_a=%s hash_b=%s five_elements=%s",
            chart_a["content_hash"][:8], chart_b["content_hash"][:8],
            compat_resp.qualitative_assessment.five_elements,
        )

        return templates.TemplateResponse(
            "compat_result.html",
            {
                "request": request,
                "chart_a": chart_a, "chart_b": chart_b,
                "compat_resp": compat_resp,
                "assessment": compat_resp.qualitative_assessment,
                "synced_fortune": compat_resp.synced_fortune,
                "context_label_zh": _CONTEXT_LABEL_ZH.get(context_label_key, context_label_key),
                "markdown_html": _render_markdown_to_html(markdown_text),
                "markdown_text": markdown_text,
                "module_name": module,
                "length_label": LENGTH_TIER_LABELS[length_tier],
                "ai_provider": client.provider,
                "ai_model": client.model,
                "prompt_version": PROMPT_VERSIONS[module],
            },
        )

    except BaziCalculationFailedError as e:
        logger.error("compat.engine_failed error=%s", e)
        return templates.TemplateResponse(
            "compat_result.html",
            _engine_error_ctx(request, e, "/compat"),
            status_code=500,
        )
    except AIProviderError as e:
        logger.error("compat.ai_failed error=%s", e)
        return templates.TemplateResponse(
            "compat_result.html",
            _ai_error_ctx(request, e, "/compat"),
            status_code=503,
        )
    except InterpretationForbiddenError as e:
        logger.warning("compat.forbidden_words_hit error=%s", e)
        return templates.TemplateResponse(
            "compat_result.html",
            _forbidden_error_ctx(request, e, "/compat"),
            status_code=422,
        )


def _calculate_two_charts(engine, birth_a, gender_a, longitude_a, birth_b, gender_b, longitude_b):
    """同步跑两人排盘(供 run_in_threadpool 调用,内部两次串行 calculate)。"""
    chart_a = engine.calculate(
        birth=birth_a, gender=gender_a,
        longitude=longitude_a, zi_hour_rule="zi_next_day",
    )
    chart_b = engine.calculate(
        birth=birth_b, gender=gender_b,
        longitude=longitude_b, zi_hour_rule="zi_next_day",
    )
    return chart_a, chart_b


def _parse_birth_from_form_with_prefix(form, prefix: str) -> tuple[datetime, str, float]:
    """带前缀的表单解析(prefix='a' 读 birth_date_a / birth_time_a / ...)。"""
    birth_date_str = form.get(f"birth_date_{prefix}")
    birth_time_str = form.get(f"birth_time_{prefix}")
    tz_offset_str = form.get(f"tz_offset_{prefix}", "8")
    gender = form.get(f"gender_{prefix}", "male")
    longitude_str = form.get(f"longitude_{prefix}", "116.4074")

    if not birth_date_str or not birth_time_str:
        raise ValueError(f"birth_date_{prefix} 和 birth_time_{prefix} 必填")

    naive = datetime.fromisoformat(f"{birth_date_str}T{birth_time_str}:00")
    tz = timezone(timedelta(hours=int(tz_offset_str)))
    birth = naive.replace(tzinfo=tz)
    return birth, gender, float(longitude_str)


# ---------- 每日运势(阶段 3) ----------

_CONTEXT_LABEL_ZH = {"general": "通用", "marriage": "婚姻", "business": "事业"}


@app.get("/daily", response_class=HTMLResponse)
async def daily_form(request: Request):
    """每日运势输入表单(出生信息 + 目标日期)。"""
    return templates.TemplateResponse(
        "daily_form.html",
        {"request": request},
    )


@app.post("/daily", response_class=HTMLResponse)
async def daily_handler(request: Request):
    """每日运势主流程:出生信息 → BaziEngine → compute_daily_fortune → AI → markdown。"""
    form = await request.form()
    try:
        birth, gender, longitude = _parse_birth_from_form(form)
        target_date_str = form.get("target_date")
        if not target_date_str:
            raise ValueError("target_date 必填")
        target_date = datetime.fromisoformat(target_date_str).date()
        length_tier = _parse_length_tier(form)
    except (ValueError, TypeError) as e:
        logger.warning("daily.form_parse_failed error=%s", e)
        return templates.TemplateResponse(
            "daily_result.html",
            _form_error_ctx(request, e, "/daily"),
            status_code=400,
        )

    try:
        # ① 先跑 BaziEngine 拿 chart_payload(用户填出生信息,不是命盘 JSON)
        engine = BaziEngine()
        chart = await run_in_threadpool(
            engine.calculate,
            birth=birth, gender=gender,
            longitude=longitude, zi_hour_rule="zi_next_day",
        )

        # ② 转 ChartPayload 类型
        chart_payload = _chart_dict_to_payload(chart)

        # ③ compute_daily_fortune
        daily_resp = await run_in_threadpool(
            compute_daily_fortune,
            chart_hash=chart["content_hash"],
            target_date=target_date,
            chart_payload=chart_payload,
        )

        # ④ 渲染 prompt + AI(网页填 key 优先,fallback env)
        client, _used_provider, _used_model = _get_client_for_request(form)
        module = "daily_fortune"
        context = build_daily_context(chart, daily_resp, target_date)
        prompt = render_prompt_with_length(module, context, length_tier)
        markdown_text = await _interpret_with_tier(client, prompt, length_tier)

        # ⑤ 禁词校验
        validate_interpretation(markdown_text)

        # ⑥ 给 chart 加派生字段(供模板对齐 iOS)
        _prepare_chart_for_template(chart)

        logger.info(
            "daily.ok content_hash=%s target=%s day_pillar=%s",
            chart["content_hash"][:8], target_date, daily_resp.day_pillar,
        )

        return templates.TemplateResponse(
            "daily_result.html",
            {
                "request": request,
                "chart": chart,
                "daily_resp": daily_resp,
                "target_date": target_date,
                "markdown_html": _render_markdown_to_html(markdown_text),
                "markdown_text": markdown_text,
                "module_name": module,
                "length_label": LENGTH_TIER_LABELS[length_tier],
                "ai_provider": client.provider,
                "ai_model": client.model,
                "prompt_version": PROMPT_VERSIONS[module],
            },
        )

    except BaziCalculationFailedError as e:
        logger.error("daily.engine_failed error=%s", e)
        return templates.TemplateResponse(
            "daily_result.html",
            _engine_error_ctx(request, e, "/daily"),
            status_code=500,
        )
    except AIProviderError as e:
        logger.error("daily.ai_failed error=%s", e)
        return templates.TemplateResponse(
            "daily_result.html",
            _ai_error_ctx(request, e, "/daily"),
            status_code=503,
        )
    except InterpretationForbiddenError as e:
        logger.warning("daily.forbidden_words_hit error=%s", e)
        return templates.TemplateResponse(
            "daily_result.html",
            _forbidden_error_ctx(request, e, "/daily"),
            status_code=422,
        )


# ---------- 命盘问答(2026-08-15 加,用户模板拆解方案 B) ----------


@app.get("/ask", response_class=HTMLResponse)
async def ask_form(request: Request):
    """命盘问答输入表单(出生信息 + 任意问题)。"""
    return templates.TemplateResponse(
        "ask_form.html", {"request": request},
    )


@app.post("/ask", response_class=HTMLResponse)
async def ask_handler(request: Request):
    """命盘问答主流程:出生信息 → BaziEngine → QA prompt(结论/根因/行动/反直觉/反问)→ AI。

    错误显式传播,与三模块同口径(engine/AI/禁词分别渲染错误页)。
    """
    form = await request.form()
    try:
        birth, gender, longitude = _parse_birth_from_form(form)
        question = (form.get("question") or "").strip()
        if not question:
            raise ValueError("问题不能为空")
    except (ValueError, TypeError) as e:
        logger.warning("ask.form_parse_failed error=%s", e)
        return templates.TemplateResponse(
            "ask_result.html",
            _form_error_ctx(request, e, "/ask"),
            status_code=400,
        )

    try:
        engine = BaziEngine()
        chart = await run_in_threadpool(
            engine.calculate,
            birth=birth,
            gender=gender,
            longitude=longitude,
            zi_hour_rule="zi_next_day",
        )
        city = form.get("city") or None
        context = build_bazi_context(chart, birth, gender, longitude, city=city)

        client, used_provider, used_model = _get_client_for_request(form)
        prompt = render_chart_qa_prompt(context, question)
        markdown_text = await client.interpret(
            prompt,
            temperature=0.6,
            max_tokens=CHART_QA_MAX_OUTPUT_TOKENS,
            timeout=CHART_QA_TIMEOUT_SECONDS,
        )

        validate_interpretation(markdown_text)
        _prepare_chart_for_template(chart)

        logger.info(
            "ask.ok content_hash=%s question_len=%d",
            chart["content_hash"][:8], len(question),
        )
        return templates.TemplateResponse(
            "ask_result.html",
            {
                "request": request,
                "chart": chart,
                "content_hash_short": chart["content_hash"][:8],
                "question": question,
                "markdown_html": _render_markdown_to_html(markdown_text),
                "markdown_text": markdown_text,
                "ai_provider": used_provider,
                "ai_model": used_model,
            },
        )

    except BaziCalculationFailedError as e:
        logger.error("ask.engine_failed error=%s", e)
        return templates.TemplateResponse(
            "ask_result.html", _engine_error_ctx(request, e, "/ask"), status_code=500,
        )
    except AIProviderError as e:
        logger.error("ask.ai_failed error=%s", e)
        return templates.TemplateResponse(
            "ask_result.html", _ai_error_ctx(request, e, "/ask"), status_code=503,
        )
    except InterpretationForbiddenError as e:
        logger.warning("ask.forbidden_words_hit error=%s", e)
        return templates.TemplateResponse(
            "ask_result.html", _forbidden_error_ctx(request, e, "/ask"), status_code=422,
        )


# ---------- v1 prompt 系统(M0-M7 链式,2026-08-13 加) ----------


@app.get("/bazi-v1", response_class=HTMLResponse)
async def bazi_v1_form(request: Request):
    """v1 链输入表单(bazi 出生信息 + M4/M5 用户输入)。"""
    return templates.TemplateResponse(
        "bazi_v1_form.html",
        {"request": request},
    )


@app.post("/bazi-v1", response_class=HTMLResponse)
async def bazi_v1_handler(request: Request):
    """v1 链主流程:出生信息 → BaziEngine → run_v1_chain(M0-M7)→ 8 module 结果。

    注意:全链 4-7 分钟(8 个 LLM 调用串行),浏览器会一直 loading。
    """
    form = await request.form()
    try:
        birth, gender, longitude = _parse_birth_from_form(form)
        city = form.get("city") or None
        user_input = V1UserInput(
            m4_age=(form.get("m4_age") or "").strip(),
            m4_current_concern=(form.get("m4_current_concern") or "").strip(),
            m5_assets_summary=(form.get("m5_assets_summary") or "").strip(),
            m5_preference=(form.get("m5_preference") or "").strip(),
        )
    except (ValueError, TypeError) as e:
        logger.warning("bazi_v1.form_parse_failed error=%s", e)
        return templates.TemplateResponse(
            "bazi_v1_result.html",
            _form_error_ctx(request, e, "/bazi-v1"),
            status_code=400,
        )

    try:
        # ① engine 排盘
        engine = BaziEngine()
        chart = await run_in_threadpool(
            engine.calculate,
            birth=birth,
            gender=gender,
            longitude=longitude,
            zi_hour_rule="zi_next_day",
        )

        # ② 选 AI client(网页填 key 优先,fallback env)
        client, used_provider, used_model = _get_client_for_request(form)

        # ③ 跑 v1 链(8 个 module 串行,~4-7 分钟)
        logger.info(
            "bazi_v1.start content_hash=%s provider=%s model=%s",
            chart["content_hash"][:8], used_provider, used_model,
        )
        statuses = await run_v1_chain(
            client=client,
            chart=chart,
            user_input=user_input,
        )

        # ④ 给 chart 加派生字段(模板展示命盘概览)
        _prepare_chart_for_template(chart)

        ok_count = sum(1 for s in statuses if s["ok"])
        logger.info(
            "bazi_v1.ok content_hash=%s modules_ok=%s/8",
            chart["content_hash"][:8], ok_count,
        )

        return templates.TemplateResponse(
            "bazi_v1_result.html",
            {
                "request": request,
                "chart": chart,
                "gender": gender,
                "statuses": statuses,
                "module_meta": V1_MODULE_META,
                "ai_provider": used_provider,
                "ai_model": used_model,
                "ok_count": ok_count,
                "total_count": len(statuses),
                "user_input": {
                    "m4_age": user_input.m4_age,
                    "m4_current_concern": user_input.m4_current_concern,
                    "m5_assets_summary": user_input.m5_assets_summary,
                    "m5_preference": user_input.m5_preference,
                },
            },
        )

    except BaziCalculationFailedError as e:
        logger.error("bazi_v1.engine_failed error=%s", e)
        return templates.TemplateResponse(
            "bazi_v1_result.html",
            _engine_error_ctx(request, e, "/bazi-v1"),
            status_code=500,
        )
    except AIProviderError as e:
        logger.error("bazi_v1.ai_failed error=%s", e)
        return templates.TemplateResponse(
            "bazi_v1_result.html",
            _ai_error_ctx(request, e, "/bazi-v1"),
            status_code=503,
        )
    except InterpretationForbiddenError as e:
        logger.warning("bazi_v1.forbidden_words_hit error=%s", e)
        return templates.TemplateResponse(
            "bazi_v1_result.html",
            _forbidden_error_ctx(request, e, "/bazi-v1"),
            status_code=422,
        )

