"""POST /api/interpret — AI 命书解读(三模块共用)。

流程(最终方案 §7):
1. 取 prompt_version = PROMPT_VERSIONS[req.module](后端配置,不从客户端读)
2. validate_context + render_prompt(纯 CPU,留 event loop),计算 prompt_hash
3. 查后端缓存(同步 → run_in_threadpool)
   命中 → 返回 InterpretResponse(cached=True)
   命中但 v1 坏 JSON(截断时代遗留)→ 删除中毒行后落穿重新生成(自愈,2026-09-27)
4. 调用选中的 AI provider(async httpx,直接 await,不走线程池)
4.4 v1 JSON 契约校验:M0-M7 输出必须完整 JSON 对象,否则 AIProviderError(503)
    不进禁词扫描、不写缓存、不返回(截断半截 JSON 一旦入缓存会被 iOS 当散文渲染)
5. 写缓存(同步 → run_in_threadpool)
6. 返回 InterpretResponse(cached=False)

线程池策略:
- validate_context + render_prompt 纯字符串操作,快,留在 event loop
- ai_client.interpret 走 async httpx 直接 await(不再占线程池,根除并发瓶颈)
- cache.get / cache.set 仍走 run_in_threadpool(SQLite 同步)
  不与 provider 调用合并:缓存命中时零 LLM 调用
- provider 调用失败时不写缓存(步骤 4 抛异常中断流程)

错误显式传播:
- provider 失败 → AIProviderError(503),不吞不返回假文本
- SQLite 失败 → InterpretationCacheError(500),不降级调用 provider
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time
import uuid
from datetime import datetime, timezone
from typing import Final, NamedTuple

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..ai.cache import InterpretationCache
from ..ai.cache_key import CacheKey
from ..ai.forbidden_words import scan as scan_forbidden_words
from ..ai.forbidden_words import validate_interpretation
from ..ai.prompts import (
    COMPATIBILITY_MODULES,
    PROMPT_VERSIONS,
    render_prompt,
    validate_context,
)
from ..ai.singleflight import SingleflightCoalescer
from ..auth.dependencies import get_current_user_id
from ..config import AI_MAX_OUTPUT_TOKENS, resolve_temperature
from ..engine.term_translations import (
    ChartJSONDecodeError,
    build_translation_term_pairs,
    translate_context,
)
from ..entitlement import EntitlementStore
from ..errors import (
    AIProviderError,
    BaziCalculationFailedError,
    EntitlementNotFoundError,
    InterpretationCacheError,
    InterpretationForbiddenError,
    InvalidInputError,
    StaleSourceError,
)
from ..models.interpret import (
    InterpretRequest,
    InterpretResponse,
    PAID_MODULES,
    TranslateRequest,
    V1_MODULES,
    V1_NEEDS_USER_INPUT,
    entitlement_base_module,
)
from .language import resolve_language

router = APIRouter()
logger = logging.getLogger(__name__)


def _hash_parent_fingerprint(fingerprint: str | None) -> str:
    """M0 structure_fingerprint → sha256 hex(作 CacheKey.parent_hash)。

    None / 空串 → 空串(M0 自身 + 老模块无 parent,缓存键维度退化为 8 维)。
    用于 v1 链式调用:M0 重算后 fingerprint 变,M1-M7 缓存自动隔离。
    """
    if not fingerprint:
        return ""
    return hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()


def _hash_user_input(req: InterpretRequest) -> str:
    """M4/M5 用户输入 → sha256 hex(作 CacheKey.user_input_hash)。

    非 M4/M5 module → 空串(老模块 + M0-M3/M6/M7 无用户输入维度)。
    用于 v1 按需模块:同 chart 同 fingerprint 但不同用户输入,M4/M5 缓存隔离。

    schema 层 m4_health_requires_user_inputs / m5_wealth_requires_user_inputs
    已保证 M4/M5 时各字段非空。此处显式 invariant 校验:若 schema 校验后
    字段仍为 None 即代码 bug,RuntimeError 显式暴露比 f-string 静默产出
    "age=None|..." 污染 hash 更安全(对齐 CLAUDE.md 错误显式传播)。
    """
    if req.module not in V1_NEEDS_USER_INPUT:
        return ""
    if req.module == "m4_health":
        if req.m4_age is None or req.m4_current_concern is None:
            raise RuntimeError(
                f"_hash_user_input invariant violated: m4_health with "
                f"age={req.m4_age!r} concern={req.m4_current_concern!r} "
                f"(schema validator should have caught this)")
        payload = f"age={req.m4_age}|concern={req.m4_current_concern}"
    elif req.module == "m5_wealth":
        if req.m5_assets_summary is None or req.m5_preference is None:
            raise RuntimeError(
                f"_hash_user_input invariant violated: m5_wealth with "
                f"assets={req.m5_assets_summary!r} "
                f"preference={req.m5_preference!r} "
                f"(schema validator should have caught this)")
        payload = (
            f"assets={req.m5_assets_summary}"
            f"|preference={req.m5_preference}"
        )
    else:
        # V1_NEEDS_USER_INPUT 扩展时漏加 handler 会显式暴露,
        # 避免新 module 被静默当 m5_wealth 处理导致缓存隔离失效
        raise RuntimeError(
            f"_hash_user_input invariant violated: module={req.module!r} "
            f"in V1_NEEDS_USER_INPUT but no hash handler "
            f"(需在 _hash_user_input 加 elif 分支)")
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _strip_code_fences(text: str) -> str:
    """剥 LLM 违约附加的 ```json 围栏(prompt 已禁,防御性容忍)。

    精确镜像 iOS OrderedJSONParser.stripCodeFences 的算法:去 ```,
    再去语言标记(连续字母),再去空白/换行,最后剥末尾围栏。
    必须逐字符对齐而非「剥首行」:若后端比 iOS 宽(如 "``` json\\n{...}"
    围栏后带空格),后端会放行入缓存,而 iOS drop-letters 遇空格即停、
    留下 "json" 前缀 parse 失败 → 退散文 = 事故形态复发。校验层只能比
    渲染层严或同等,不能更宽。非围栏开头(正常契约输出)原样返回。
    """
    t = text.strip()
    if not t.startswith("```"):
        return t
    t = t[3:]
    i = 0
    while i < len(t) and t[i].isalpha():
        i += 1
    t = t[i:].lstrip()
    fence_end = t.rfind("```")
    if fence_end != -1:
        t = t[:fence_end]
    return t.strip()


def _is_renderable_top_level(value: object) -> bool:
    """顶层值是否可被 iOS ChapterContent.node 渲染(镜像其 nil 规则)。

    iOS 口径:string/number/bool → 节点;object → 恒成节;null → nil;
    array → 仅全 null / 空数组才 nil(arrayNode 的 nonNull 过滤)。
    校验层只能比渲染层严或同等,不能更宽(更宽 = 放行渲染层退散文的
    内容入缓存 = JSON 裸奔事故复发通道)。
    """
    if value is None:
        return False
    if isinstance(value, list):
        return any(item is not None for item in value)
    return True


def _validate_v1_module_json(module: str, interpretation: str) -> None:
    """v1 深度模块(M0-M7)输出契约 = 完整 JSON 对象(2026-09-27)。

    背景:真机 m1_talent 实证——LLM 输出在 max_tokens 截断 → 半截 JSON
    通过禁词扫描入缓存 → iOS ChapterContent.parse 失败退回散文,正文
    JSON 裸奔。此校验把「非合法 JSON」从「静默成功」改为显式 AIProviderError,
    截断/违约内容不写缓存、不返回。

    口径与 iOS 渲染层对齐:容忍围栏(剥后校验),顶层必须是对象
    (iOS `guard case .object` 同款),且至少一个顶层值可渲染
    (iOS `nodes.isEmpty → nil` 退散文的同款规则,空对象/全 null 同样拒绝)。

    Raises:
        AIProviderError: 非 JSON / 顶层非对象 / 顶层无可渲染值
            (疑似截断或违约)
    """
    if module not in V1_MODULES:
        return
    text = _strip_code_fences(interpretation)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        raise AIProviderError(
            f"v1 模块 {module} 输出非合法 JSON(疑似 max_tokens 截断或"
            f"格式违约):{e}"
        ) from e
    if not isinstance(parsed, dict):
        raise AIProviderError(
            f"v1 模块 {module} 输出 JSON 顶层非对象"
            f"(type={type(parsed).__name__},契约要求对象)"
        )
    if not any(_is_renderable_top_level(v) for v in parsed.values()):
        raise AIProviderError(
            f"v1 模块 {module} 输出 JSON 顶层无可渲染值"
            f"(空对象或全 null,iOS 渲染层会退回散文导致 JSON 裸奔)"
        )


# daily_fortune v4(S6,2026-09-30)五段契约键。镜像 iOS DailyInsight.parse:
# 五键全为非空字符串;多余键宽容(前向演进);缺失/null/空串 → 拒绝。
_DAILY_FORTUNE_INSIGHT_KEYS: tuple[str, ...] = (
    "headline", "work", "relationships", "energy", "reminder",
)


def _validate_daily_fortune_json(module: str, interpretation: str) -> None:
    """daily_fortune v4(S6,2026-09-30)输出契约 = JSON 五键非空字符串。

    背景(2026-09-30 review,red-team):M0-M7 有 JSON 契约校验(2026-09-27)
    而 daily_fortune v4 改 JSON 输出后没有——违约输出会进双层缓存;
    iOS 渲染层 DailyInsight.parse 失败走引擎模板降级,且本地 24h 缓存
    先于一切读取,Retry 只会拿回同一段坏文本(缓存毒化,静默卡到次日)。
    此校验把违约从静默成功改为显式 AIProviderError(503):不写缓存、
    不返回;缓存命中路径同样校验,坏行删除后落穿重新生成
    (与 v1 契约自愈同理)。

    口径与 iOS 渲染层对齐(DailyInsight.parse):容忍围栏;五键必须为
    非空字符串(strip 后非空——比 iOS 的 isEmpty 略严,校验层只严不宽);
    多余键宽容。

    Raises:
        AIProviderError: 非 JSON / 顶层非对象 / 五键缺失或非字符串或空白
    """
    if module != "daily_fortune":
        return
    text = _strip_code_fences(interpretation)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        raise AIProviderError(
            f"daily_fortune v4 输出非合法 JSON(疑似 max_tokens 截断或"
            f"格式违约):{e}"
        ) from e
    if not isinstance(parsed, dict):
        raise AIProviderError(
            f"daily_fortune v4 输出 JSON 顶层非对象"
            f"(type={type(parsed).__name__},契约要求五键对象)"
        )
    bad = [
        k for k in _DAILY_FORTUNE_INSIGHT_KEYS
        if not isinstance(parsed.get(k), str) or not parsed[k].strip()
    ]
    if bad:
        raise AIProviderError(
            f"daily_fortune v4 输出五键残缺或非字符串"
            f"(缺失/空值: {', '.join(bad)};"
            f"iOS 渲染层会整体降级,不进缓存)"
        )


# ---------- 合盘后置处理(2026-09-27:名字化 + 干支接地观测)----------

# A/B 代号替换覆盖的 module(alias + M4 拆分;老 iOS alias 请求无名字 →
# setdefault 兜底 "A"/"B",替换退化为恒等,无害)。
# 单一事实源 = prompts.COMPATIBILITY_MODULES,与 render_prompt 名字兜底共用。
_COMPAT_POSTPROCESS_MODULES: frozenset[str] = COMPATIBILITY_MODULES

# standalone「A」/「B」:前后都不是 ASCII 字母数字(误伤 Amanda / H1B / A4 这类词
# ——测试实证:H1B 的 B 前是数字,只挡字母挡不住);
# 吞掉代号后的一个半角空格(「A 倾向于」→「你倾向于」,中文排版无残留空格)
_STANDALONE_AB = re.compile(r"(?<![A-Za-z0-9])([AB])\s?(?![A-Za-z0-9])")

# 两人称呼遮罩占位符:核心是 NUL 包夹控制字符,LLM 正文不会出现。
# 边缘哨兵:非 A/B 的 ASCII 字母数字(具体字符按对方名字避让,见候选
# 常量)——代号轮 ([AB]) 永不命中,只在名字边缘字符是 ASCII 字母数字时
# **同侧**出现,复现该边缘给邻接正文字母的环视保护(2026-09-29 外部
# review 实证:「小 A」遮罩成全控制符后,「小 AB」的 B 因前邻变非字母
# 数字而裸露成 standalone 被吃)。
_AB_SHIELD_CORE_A = "\x00\x01\x00"
_AB_SHIELD_CORE_B = "\x00\x02\x00"
# 哨兵候选:ASCII 字母数字但**非 A/B**(代号轮 ([AB]) 永不命中)。取首个
# 不与对方名字首/末字符相同的——对方名字跨哨兵伪命中时哨兵只能落在其
# 首或末字符(更深的重叠须含控制符核心,用户别名不含控制符),避让两条
# 边后伪命中在两个方向都不可能发生,遮罩互不吞边(2026-09-29 差分 fuzz
# 实证:固定 'x' 时 "A.2"/"x A" 名字对互吞,还原失配后控制符裸漏正文)。
_AB_SHIELD_SENTINEL_CANDIDATES = ("x", "y", "z", "u", "v", "w")
# 与 _STANDALONE_AB 的环视类逐字符同源([A-Za-z0-9]),判定边性用
_ASCII_ALNUM = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
)


def _shield_for(name: str, other: str, core: str) -> str:
    """按名字边缘字符的 ASCII 字母数字性给占位符配边。

    名字首/尾是 ASCII 字母数字(即 standalone 判定的"保护边")时,占位符
    同侧带哨兵——紧贴名字的邻接正文字母(「AB」「BA」里的另一个字母)
    的环视结论与名字在场时一致,不被遮罩拆掉保护;名字边缘非 ASCII 字母
    数字则保持控制字符裸边,邻接字母原本可替换的语义同样不变。

    哨兵按 ``other``(另一轴名字)的首/末字符避让,防跨名吞边:后遮的
    名字若在已遮罩文本里跨哨兵伪命中,会把前一遮罩的哨兵吞进自己的
    替换区间,还原失配 → 控制符裸漏。环视保护只要求哨兵是字母数字,
    具体取哪个字符不影响保护语义,避让零代价。"""
    avoid = {other[0], other[-1]} if other else set()
    sentinel = next(
        c for c in _AB_SHIELD_SENTINEL_CANDIDATES if c not in avoid)
    head = sentinel if name[0] in _ASCII_ALNUM else ""
    tail = sentinel if name[-1] in _ASCII_ALNUM else ""
    return f"{head}{core}{tail}"


def _replace_ab_labels(text: str, name_a: str, name_b: str) -> str:
    """合盘解读里残留的 A/B 代号 → 两人称呼(确定性替换,prompt 之外的兜底)。

    prompt v4 已要求全文用 name_a/name_b 称呼,但 LLM 违约时叙述里仍可能冒出
    「A 倾向于先说结论」。用户要求不只依赖 prompt,此处后置替换。

    两类替换事故同源——**名字本身含 standalone 代号字母**(「A先生」「小B」;
    输入提示「如相亲对象甲」下「对象B」类称呼很自然):
    ① 同轴自伤:正文里合规写出的「A先生」其 A 被再替换 →「A先生先生」;
    ② 交叉轴污染(2026-09-28 外部 review 实证):name_a 含 standalone B 时,
      A 轮注入的「小B」被 B 轮吃掉 → A 的称呼变成「小丽」——命理用户一处错
      即怀疑整篇,且老实现的 skip-guard 只查同轴,交叉轴完全不设防。
    解法两步走:
    - **遮罩**:先把正文里出现的两人称呼整体换成控制符核心占位符——名字内的
      字母彻底退出代号轮视野,①②连同「合规名字写在原文里被吃」一并消除;
      长名先遮,防双遮罩前缀对(短名 ⊂ 长名前缀)被短名剥壳后长名内
      露出的代号字母遭代号轮吃(「小B」/「小B小A」,实测短名先遮产出
      「小B小小B快」)。附带收益:
      名字含代号字母时裸代号也照替(老 skip-guard 是整轴放弃,裸代号残留)。
      遮罩只施于**含 standalone 代号字母的名字**:Bella/Amy 类(内部字母全
      非 standalone)不遮——遮了反而拆掉其首尾字母给邻接字母提供的环视
      保护(「AmyB」的 B 前邻 'y' 换成控制符后被当 standalone 吃掉,差分
      fuzz 实证 71/4000 漂移全属此类),不遮则与老实现逐字节平价。
      **被遮名字的同款保护由占位符边缘哨兵复现**(`_shield_for`,2026-09-29
      外部 review 实证):「小 A」「对象B」类名字的边缘字母本身是 standalone,
      遮罩后其给邻接正文字母(「AB 同频」里的 B)提供的环视保护会随控制符
      裸边消失——B 被当 standalone 吃成「小 A丽同频」。占位符在名字边缘
      为 ASCII 字母数字的同侧带哨兵(非 A/B 的字母数字,代号轮永不命中),
      环视结论与名字在场时逐字节一致;边缘非字母数字则裸边,不额外制造
      保护。哨兵字符按对方名字首/末字符避让——固定字符会被边缘恰为该字符
      的对方名字跨吞(遮罩互吞 → 还原失配 → 控制符裸漏正文,差分 fuzz
      实证),避让后伪命中几何上不可能。
    - **单遍替换**:一轮 re.sub 只扫原文、不回扫替换结果,注入名字里的字母
      天然不会被再吃(老实现两轮先后跑,B 轮重扫 A 轮产物,即②根因)。
    名字内部的非 standalone 字母(Bella/Amy)由环视天然保护,无需遮罩介入。
    替换与遮罩还原均按字面进行:代号轮用函数式替换(lambda)——字符串 repl
    会解析 \\ 转义(别名以 \\ 结尾抛 re.error bad escape、\\1/\\g 错插组引用,
    用户输入可触发 interpret 500);遮罩/还原走 str.replace,同样零转义解析。
    """
    # 遮罩:长名先遮(前缀名防残根);空名不遮(str.replace("",…) 会在每个
    # 字符间插占位符,且空名无称呼可保护);无 standalone 代号字母的名字
    # 不遮(环视天然保护,遮了反拆邻接字母的保护,见 docstring);
    # 占位符边缘按名字边缘字母数字性配哨兵(护住紧贴名字的邻接代号字母,
    # 哨兵避让对方名字首/末字符,防跨名吞边)
    shields: list[tuple[str, str]] = []
    for name, other, core in sorted(
        (
            (name_a, name_b, _AB_SHIELD_CORE_A),
            (name_b, name_a, _AB_SHIELD_CORE_B),
        ),
        key=lambda triple: len(triple[0]), reverse=True,
    ):
        if name and _STANDALONE_AB.search(name):
            shield = _shield_for(name, other, core)
            text = text.replace(name, shield)
            shields.append((shield, name))

    names = {"A": name_a, "B": name_b}

    def _repl(m: re.Match) -> str:
        # 空名(防御,契约上 setdefault 后不会出现):该代号原样保留
        return names[m.group(1)] or m.group(0)

    text = _STANDALONE_AB.sub(_repl, text)
    for shield, name in shields:
        text = text.replace(shield, name)
    return text


# A/B 代号兜底替换的适用语言:仅中文(2026-10-02 修复)。en 模板明令禁用
# A/B 代号(v4 "never use labels like A, B"),英文里 standalone "A" 首先
# 是冠词——"A steady rhythm" 会被替换成「小美 steady rhythm」并写进跨用户
# 共享缓存;中文里独立 A/B 才是无歧义的代号违约信号。
_AB_LABEL_REPLACE_LANGUAGES: Final[frozenset[str]] = frozenset({"zh", "zh-hant"})


def _maybe_replace_ab_labels(
    text: str, name_a: str, name_b: str, language: str,
) -> str:
    """语言门控的 A/B 代号兜底替换(见 _AB_LABEL_REPLACE_LANGUAGES 注释)。"""
    if language not in _AB_LABEL_REPLACE_LANGUAGES:
        return text
    return _replace_ab_labels(text, name_a, name_b)


# 天干地支全集(干支接地观测用;与 engine/pillars.py 的表同源字符集)
_TIANGAN_CHARS = frozenset("甲乙丙丁戊己庚辛壬癸")
_DIZHI_CHARS = frozenset("子丑寅卯辰巳午未申酉戌亥")
_GANZHI_CHARS = _TIANGAN_CHARS | _DIZHI_CHARS

# 允许引用的干支来源字段:两人四柱 + 流年同步表(含大运/流年干支)
_COMPAT_GANZHI_SOURCE_FIELDS: tuple[str, ...] = (
    "year_a", "month_a", "day_a", "hour_a",
    "year_b", "month_b", "day_b", "hour_b",
    "synced_fortune_table",
)


def _log_offchart_ganzhi(
    interpretation: str, context: dict, log_ctx: dict,
) -> None:
    """观测:输出提及了输入数据里不存在的干支字符(prompt 接地违约信号)。

    **log-only 不拦截**(2026-09-27 拍板):「子时」「申金」等泛指说明也会
    命中字符集,硬拦误伤正常生成;先收集违规率,高频再谈强校验。
    """
    allowed: set[str] = set()
    for field in _COMPAT_GANZHI_SOURCE_FIELDS:
        value = context.get(field)
        if isinstance(value, str):
            allowed |= {c for c in value if c in _GANZHI_CHARS}
    mentioned = {c for c in interpretation if c in _GANZHI_CHARS}
    # 两人称呼已由 _replace_ab_labels 注入正文;名字里恰含干支字(如「陈寅」
    # 「丁一」)属称呼本身而非 LLM 引用盘外干支,从观测集合剔除防污染信号
    # (log-only 拍板不变,此处只提升违约率统计的准确性)。
    name_chars = {
        c for c in (context.get("name_a") or "") + (context.get("name_b") or "")
        if c in _GANZHI_CHARS
    }
    offchart = mentioned - name_chars - allowed
    if offchart:
        logger.warning(
            "interpret.compat_offchart_ganzhi %s offchart=%s "
            "(输出提及但两盘四柱/大运/流年中不存在的干支字符,"
            "prompt 接地违约观测,不拦截)",
            log_ctx, sorted(offchart),
        )


# ---------- 端点共享层(D10.1:两个端点共用,禁止复制粘贴) ----------

class _PreparedPrompt(NamedTuple):
    """「校验 → context 翻译 → 渲染 → 算缓存键」的共享产物。

    /api/interpret 直接把 prompt 发给 LLM;/api/interpret/translate 只消费
    cache_key(渲染出的目标语言 prompt 决定 prompt_hash 维度——这正是
    「译文写入的键 = 目标语言正常生成会算出的键」对齐的机制:
    两个端点跑同一段代码,不复制粘贴)。
    """

    prompt_version: int
    translated_context: dict
    prompt: str
    cache_key: CacheKey
    log_ctx: dict


def _prepare_prompt_and_key(
    req: InterpretRequest,
    language: str,
    request_id: str,
    start: float,
    ai_client,
) -> _PreparedPrompt:
    """取版本 → context 翻译 → 校验 → 渲染 → hash → CacheKey(共享,纯 CPU)。

    错误包装与 /api/interpret 原行为逐字对齐(InvalidInputError 422 /
    术语 KeyError → BaziCalculationFailedError 500 / ChartJSONDecodeError →
    结构化 500 / FileNotFoundError → 500),两个端点的错误面一致。
    """
    # 1. 取 prompt_version(后端配置,不从客户端读)
    prompt_version = PROMPT_VERSIONS.get(req.module)
    if prompt_version is None:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.warning(
            "interpret.module_not_registered elapsed_ms=%.1f request_id=%s "
            "module=%s content_hash=%s",
            elapsed_ms, request_id, req.module, req.content_hash,
        )
        raise InvalidInputError(
            f"module={req.module} 尚未支持(PROMPT_VERSIONS 未注册)",
            request_id=request_id,
        )
    target_date_str = str(req.target_date) if req.target_date else None

    # 2. 校验 context + 渲染 prompt。缓存键必须覆盖 prompt 内容,否则同一
    # content_hash 携带不同 context 会污染跨用户缓存。
    try:
        translated_context = translate_context(req.context, language, req.module)
        validate_context(req.module, translated_context)
        prompt = render_prompt(req.module, translated_context, language=language)
    except InvalidInputError as e:
        e.request_id = request_id
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.warning(
            "interpret.validate_failed elapsed_ms=%.1f request_id=%s "
            "content_hash=%s module=%s target_date=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            target_date_str, e,
            exc_info=True,
        )
        raise
    except KeyError as e:
        # translate_context 术语未注册 → 500(后端配置问题,非用户错误)
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.translate_context_failed elapsed_ms=%.1f request_id=%s "
            "content_hash=%s module=%s language=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            language, e,
            exc_info=True,
        )
        raise BaziCalculationFailedError(
            f"术语翻译失败({e}),需补齐 term_translations.py 翻译表",
            request_id=request_id, content_hash=req.content_hash,
        ) from e
    except ChartJSONDecodeError as e:
        # 客户端提交的 chart 字段非 JSON → 结构化 500(2026-09-23 收窄口径)
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.translate_context_invalid_chart elapsed_ms=%.1f "
            "request_id=%s content_hash=%s module=%s language=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            language, e,
            exc_info=True,
        )
        raise BaziCalculationFailedError(
            f"context.chart 非合法 JSON({e}),"
            f"深度解析 chart 字段须为 JSON 字符串(v1 §1 schema)",
            request_id=request_id, content_hash=req.content_hash,
        ) from e
    except FileNotFoundError as e:
        # render_prompt 模板文件缺失 → 500(后端配置问题)
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.template_missing elapsed_ms=%.1f request_id=%s "
            "content_hash=%s module=%s language=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            language, e,
            exc_info=True,
        )
        raise BaziCalculationFailedError(
            f"prompt 模板缺失({e}),需补齐 prompts/{{language}}/ 目录",
            request_id=request_id, content_hash=req.content_hash,
        ) from e

    prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    parent_hash = _hash_parent_fingerprint(req.parent_fingerprint)
    user_input_hash = _hash_user_input(req)

    log_ctx = {
        "request_id": request_id,
        "content_hash": req.content_hash,
        "module": req.module,
        "prompt_version": prompt_version,
        "target_date": target_date_str,
        "prompt_hash": prompt_hash,
        "provider": ai_client.provider,
        "model": ai_client.model,
        "parent_hash": parent_hash,
        "user_input_hash": user_input_hash,
        "language": language,
    }
    cache_key = CacheKey(
        content_hash=req.content_hash,
        module=req.module,
        prompt_version=prompt_version,
        target_date=target_date_str,
        prompt_hash=prompt_hash,
        provider=ai_client.provider,
        model=ai_client.model,
        parent_hash=parent_hash,
        user_input_hash=user_input_hash,
        language=language,
    )
    return _PreparedPrompt(
        prompt_version=prompt_version,
        translated_context=translated_context,
        prompt=prompt,
        cache_key=cache_key,
        log_ctx=log_ctx,
    )


async def _require_entitlement(
    request: Request,
    req: InterpretRequest,
    current_user_id: str | None,
    request_id: str,
) -> None:
    """付费 module 的 entitlement 检查(/api/interpret 与 /translate 同一道)。

    权益与语言无关:翻译不另收费、不消耗任何次数(D10.1)。
    """
    if req.module not in PAID_MODULES:
        return
    base_module = entitlement_base_module(req.module)
    entitlement_store: EntitlementStore = request.app.state.entitlement_store
    try:
        entitlement = await run_in_threadpool(
            entitlement_store.get_active,
            content_hash=req.content_hash,
            module=base_module,
            user_local_id=req.user_local_id,  # type: ignore[arg-type]
            user_id=current_user_id,
        )
    except Exception as e:
        logger.exception(
            "interpret.entitlement_check_failed request_id=%s "
            "content_hash=%s module=%s error=%r",
            request_id, req.content_hash, req.module, e)
        raise InterpretationCacheError(
            f"entitlement 查询失败({type(e).__name__}): {e}",
            request_id=request_id, content_hash=req.content_hash,
        ) from e
    if entitlement is None:
        logger.warning(
            "interpret.entitlement_not_found request_id=%s "
            "content_hash=%s base_module=%s",
            request_id, req.content_hash, base_module)
        raise EntitlementNotFoundError(
            f"未找到有效 entitlement(module={base_module} "
            f"content_hash={req.content_hash})",
            request_id=request_id, content_hash=req.content_hash,
        )


async def _load_validated_cache_row(
    cache: InterpretationCache,
    cache_key: CacheKey,
    module: str,
    log_ctx: dict,
    request_id: str,
    content_hash: str,
    start: float,
) -> dict | None:
    """查缓存 + 命中行的禁词/JSON 契约自愈(两端点共享)。

    Returns:
        命中且健康的行(含 interpretation / generated_at / provider / model),
        或 None(未命中 / 中毒行已删除落穿)。

    Raises:
        InterpretationCacheError(读/删失败) / InterpretationForbiddenError
        (命中行含禁词,删后显式拦截)
    """
    try:
        cached_row = await run_in_threadpool(cache.get, cache_key)
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.cache_get_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise InterpretationCacheError(
            f"后端缓存读失败({type(e).__name__}): {e}") from e

    if cached_row is None:
        return None

    # 禁词扫描(防止老缓存被污染,US-COMP-04)
    forbidden_hits = scan_forbidden_words(cached_row["interpretation"])
    if forbidden_hits:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.warning(
            "interpret.cache_forbidden elapsed_ms=%.1f %s hits=%s",
            elapsed_ms, log_ctx, forbidden_hits,
        )
        await _invalidate_poisoned_cache(cache, cache_key, log_ctx)
        raise InterpretationForbiddenError(
            f"AI 解读包含禁词,已拦截(命中: {', '.join(forbidden_hits)})",
            request_id=request_id,
            content_hash=content_hash,
        )
    # v1 JSON 契约自愈(2026-09-27)+ daily v4 五键自愈(2026-09-30):
    # 坏行删除后落穿重新生成(纵深防御,详见 /api/interpret 步骤 3 注释)
    try:
        _validate_v1_module_json(module, cached_row["interpretation"])
        _validate_daily_fortune_json(module, cached_row["interpretation"])
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.warning(
            "interpret.cache_invalid_json elapsed_ms=%.1f %s error=%s"
            " — 删除中毒缓存,落穿重新生成",
            elapsed_ms, log_ctx, e,
        )
        await _invalidate_poisoned_cache(cache, cache_key, log_ctx)
        return None
    return cached_row


@router.post("/api/interpret", response_model=InterpretResponse)
async def interpret(
    req: InterpretRequest,
    request: Request,
    current_user_id: str | None = Depends(get_current_user_id),
) -> InterpretResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    # 1.5 i18n:解析目标语言(从 X-QiCompass-Lang / Accept-Language header)
    # 解析层见 backend/app/api/language.py(i18n 决策 2:方案 4 双 header 混合)
    language = resolve_language(request)

    ai_client = request.app.state.ai_client

    # 1-2. 校验 context + 渲染 prompt + 算缓存键(与 /api/interpret/translate
    # 共享 _prepare_prompt_and_key——D10.1 缓存键对齐的关键:两个端点跑同一段
    # 代码,译文写入的键与目标语言正常生成的键逐字段相等)
    prepared = _prepare_prompt_and_key(req, language, request_id, start, ai_client)
    prompt_version = prepared.prompt_version
    translated_context = prepared.translated_context
    prompt = prepared.prompt
    cache_key = prepared.cache_key
    log_ctx = prepared.log_ctx
    logger.info("interpret.start %s", log_ctx)

    # 2.5 Entitlement 检查(仅 PAID_MODULES;MONETIZATION.md M2 越狱保护核心防线)
    # 越狱设备绕过 iOS UI 直调 /api/interpret 付费 module → 此处拦下;
    # base module 映射(entitlement_base_module 单一事实源):
    # bazi_deep_paid / v1 m2-m7 → "bazi_deep"(单 SKU 解锁该盘全部深度付费内容)
    # compatibility_paid / compatibility alias → "compatibility"
    # 2026-08-23 修复:v1 m2-m7 此前按原名查 entitlement,而 iOS redeem 恒写
    # "bazi_deep" → 已购用户点 M2-M7 也 403(跨层断链),统一映射后闭合
    await _require_entitlement(request, req, current_user_id, request_id)

    cache: InterpretationCache = request.app.state.cache

    # 3. 查后端缓存(禁词 + JSON 契约自愈,与 translate 端点共享)
    cached_row = await _load_validated_cache_row(
        cache, cache_key, req.module, log_ctx, request_id, req.content_hash,
        start,
    )
    if cached_row is not None:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.info(
            "interpret.cache_hit elapsed_ms=%.1f %s",
            elapsed_ms, log_ctx,
        )
        return InterpretResponse(
            interpretation=cached_row["interpretation"],
            prompt_version=prompt_version,
            cached=True,
            generated_at=cached_row["generated_at"],
            provider=cached_row["provider"],
            model=cached_row["model"],
            language=language,
        )

    # 4. 调用选中 provider(async httpx 直接 await,不走线程池)
    #    singleflight 合并:同 key 并发只调一次 LLM,所有等待者共享结果
    #    (成本 + 延迟双省;多 worker 下各自独立,跨进程合并是 v2 Redis 的事)
    # v1 prompt 系统:按 module 分级 temperature(M0-M2=0.3 稳结构,M3-M7=0.6
    # 重质感,老模块=0.6 向后兼容);Stage 2 已铺基础设施,此处接入路由
    logger.info("interpret.provider_called %s", log_ctx)
    sf: SingleflightCoalescer = request.app.state.llm_singleflight
    # CacheKey 是 frozen dataclass,自动 hashable,直接作 singleflight dict key
    # (语义对齐:同 cache key 的并发 LLM 调用合并为一次)
    sf_key = cache_key
    temperature = resolve_temperature(req.module)
    try:
        interpretation = await sf.coalesce(
            sf_key, lambda: ai_client.interpret(
                prompt, temperature=temperature,
            ),
        )
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.provider_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        e.request_id = request_id
        raise
    # 非预期异常(AttributeError/TypeError 等代码 bug)不包装,
    # 向上抛由全局 handler 处理为 500,避免用 503 掩盖代码缺陷

    # 4.2 合盘后置处理(2026-09-27):A/B 代号确定性替换 + 干支接地违约观测。
    # 在禁词扫描/写缓存之前——扫描与缓存看到的都是最终文本。
    # 名字从 translated_context 取(老客户端无名字 → render_prompt 已 setdefault
    # 兜底 "A"/"B",替换退化为恒等)。
    if req.module in _COMPAT_POSTPROCESS_MODULES:
        interpretation = _maybe_replace_ab_labels(
            interpretation,
            translated_context.get("name_a") or "A",
            translated_context.get("name_b") or "B",
            language,
        )
        _log_offchart_ganzhi(interpretation, translated_context, log_ctx)

    # 4.4 v1 JSON 契约校验(2026-09-27):M0-M7 输出必须是完整 JSON 对象。
    # 截断/违约 → AIProviderError(503),不进禁词扫描、不写缓存、不返回
    # (半截 JSON 一旦入缓存,iOS 渲染层 parse 失败退回散文 = 正文 JSON 裸奔,
    # 真机 m1_talent 实证)。失败 refund 由 iOS 端重试链路承接(重试不耗次数)。
    # daily_fortune v4 五键契约同门(2026-09-30):违约不进双层缓存,
    # 防 iOS 端「Retry 拿回同一段坏文本」的缓存毒化循环。
    try:
        _validate_v1_module_json(req.module, interpretation)
        _validate_daily_fortune_json(req.module, interpretation)
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        e.request_id = request_id
        logger.error(
            "interpret.v1_invalid_json elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise

    # 4.5 禁词扫描(LLM 输出守卫,US-COMP-04)
    # 命中即拦截:不替换文本,不写缓存,不返回原文,直接抛错让客户端进入 error 态
    validate_interpretation(
        interpretation,
        request_id=request_id,
        content_hash=req.content_hash,
        log_ctx=log_ctx,
    )

    # 5. 写缓存(同步 → 线程池)
    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        await run_in_threadpool(
            cache.set, cache_key, interpretation, now_iso,
        )
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.cache_set_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise InterpretationCacheError(
            f"后端缓存写失败({type(e).__name__}): {e}") from e

    # 6. 返回
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "interpret.ok elapsed_ms=%.1f cached=False %s",
        elapsed_ms, log_ctx,
    )
    return InterpretResponse(
        interpretation=interpretation,
        prompt_version=prompt_version,
        cached=False,
        generated_at=now_iso,
        provider=ai_client.provider,
        model=ai_client.model,
        language=language,
    )


async def _invalidate_poisoned_cache(
    cache: InterpretationCache,
    cache_key: CacheKey,
    log_ctx: dict,
) -> None:
    """删除被污染的缓存条目(禁词命中 / v1 坏 JSON)。失败抛 InterpretationCacheError(不吞,避免坏缓存无限循环)。

    设计决策:删除失败时不静默吞,因为吞掉会导致同一坏缓存被反复命中,
    用户每次重试都拿到同样的禁词错误,形成无限循环。抛 InterpretationCacheError
    让用户看到"缓存故障"(不同于"禁词拦截"),知道是基础设施问题。
    """
    try:
        await run_in_threadpool(cache.delete, cache_key)
    except Exception as e:
        logger.exception(
            "interpret.cache_delete_failed %s error=%s "
            "cached entry remains poisoned, manual cleanup may be needed",
            log_ctx, e,
        )
        raise InterpretationCacheError(
            f"删除被禁词污染的缓存失败({type(e).__name__}): {e}"
        ) from e


# ---------- POST /api/interpret/translate(D10,2026-10-01) ----------

# 客户端提交原文的长度硬上限:按 max_tokens × 语言系数折算字符数(D10.1)。
# zh/zh-hant ≈ 1 字/token(×1.5 含 JSON 结构开销余量);en ≈ 4 字符/token——
# 统一 ×1.5 是按中文估的,en 长章(M1/M2/M3/M5/M7)合法输出可到 12k-16k 字符,
# 会被误伤 422 → en→中翻译永久不可用(2026-10-02 修复,按 source_language 分档)。
# 上限目的只是拦「非本模块解读文本 / 滥用翻译端点当通用翻译器」,系数取宽侧。
_SOURCE_INTERPRETATION_CHAR_LIMITS: Final[dict[str, int]] = {
    "zh": int(AI_MAX_OUTPUT_TOKENS * 1.5),
    "zh-hant": int(AI_MAX_OUTPUT_TOKENS * 1.5),
    "en": int(AI_MAX_OUTPUT_TOKENS * 4),
}

# 翻译端点的合盘后置处理范围(不含 alias:白名单 TRANSLATE_MODULES 已排除)
_TRANSLATE_COMPAT_MODULES: Final[frozenset[str]] = frozenset({
    "compatibility_free", "compatibility_paid",
})

# 合盘章节标题行(iOS CompatibilityInterpretationSection 同款口径:zh/zh-hant
# 「第X章 …」/ en "Chapter N …";X 为汉字数字)
_CHAPTER_TITLE_RE: Final[re.Pattern[str]] = re.compile(
    r"^(?:第[一二三四五六七八九十]+章|Chapter\s+\d+)", re.MULTILINE)


def _render_translate_prompt(
    source_language: str, target_language: str, source_interpretation: str,
) -> str:
    """拼翻译 prompt(translate_v1.md 按**目标语言**取件 + 术语对 + 原文)。

    原文以拼接方式附加(不走 str.format_map):v1 模块原文是 JSON,含大量
    字面花括号,进 format_map 会 KeyError/误替换——模板只渲染 {term_table}
    一个安全占位符(术语对内容无花括号)。
    """
    from ..ai.prompts import _load_template

    pairs = build_translation_term_pairs(source_language, target_language)
    term_table = "\n".join(f"- {src} → {tgt}" for src, tgt in pairs)
    template = _load_template(
        "translate", target_language, PROMPT_VERSIONS["translate"])
    prompt = template.format_map({"term_table": term_table})
    return f"{prompt}{source_interpretation}\n===== 原文结束 ====="


def _count_chapter_titles(text: str) -> int:
    """合盘正文的章标题行数(zh「第X章」/ en "Chapter N" 合计)。"""
    return len(_CHAPTER_TITLE_RE.findall(text))


def _assert_json_structural_identity(
    source: object, translated: object, path: str = "$",
) -> None:
    """v1 模块译文与原文 JSON 的递归同构校验(D10.3 #1)。

    规则:dict 键集合相同(递归);list 长度相同(递归);非字符串标量
    (数字/布尔/null)逐值相等;字符串可不同(那正是翻译的部分)。

    Raises:
        AIProviderError: 任一层不同构(译文疑似增删改了结构/数字/枚举)
    """
    if isinstance(source, dict) and isinstance(translated, dict):
        src_keys, tgt_keys = set(source), set(translated)
        if src_keys != tgt_keys:
            raise AIProviderError(
                f"译文 JSON 与原文不同构({path}: 键集合漂移,"
                f"仅原文={sorted(src_keys - tgt_keys)} "
                f"仅译文={sorted(tgt_keys - src_keys)})")
        for key in source:
            _assert_json_structural_identity(
                source[key], translated[key], f"{path}.{key}")
        return
    if isinstance(source, list) and isinstance(translated, list):
        if len(source) != len(translated):
            raise AIProviderError(
                f"译文 JSON 与原文不同构({path}: 数组长度 "
                f"{len(source)} → {len(translated)},禁止增删条目)")
        for i, (s, t) in enumerate(zip(source, translated)):
            _assert_json_structural_identity(s, t, f"{path}[{i}]")
        return
    if isinstance(source, str) and isinstance(translated, str):
        return  # 字符串值:翻译目标本身,允许不同
    if source is None or translated is None:
        if source is not translated:
            raise AIProviderError(
                f"译文 JSON 与原文不同构({path}: null 漂移"
                f" {source!r} → {translated!r})")
        return
    if isinstance(source, (bool, int, float)) and isinstance(
            translated, (bool, int, float)):
        if source != translated:
            raise AIProviderError(
                f"译文 JSON 与原文不同构({path}: 非字符串值被改动 "
                f"{source!r} → {translated!r},禁止改数字/布尔)")
        return
    raise AIProviderError(
        f"译文 JSON 与原文不同构({path}: 值类型漂移 "
        f"{type(source).__name__} → {type(translated).__name__})")


def _parse_v1_source_interpretation(
    module: str, source_interpretation: str,
) -> dict:
    """v1 模块客户端原文的形状校验(InvalidInputError = 422,客户端输入错误)。

    端点在烧 LLM **之前**调用(客户端 bug / 滥用请求不该产生 provider 成本),
    `_assert_translation_fidelity` 复用同一解析(与译文同构比对)。
    """
    try:
        parsed = json.loads(_strip_code_fences(source_interpretation))
    except json.JSONDecodeError as e:
        raise InvalidInputError(
            f"source_interpretation 不是 {module} 形状的合法 JSON"
            f"({e};v1 模块原文应为完整 JSON 对象)") from e
    if not isinstance(parsed, dict):
        raise InvalidInputError(
            f"source_interpretation JSON 顶层非对象(module={module},"
            f"v1 契约要求对象)")
    return parsed


def _assert_translation_fidelity(
    module: str,
    source_interpretation: str,
    translated: str,
    name_a: str | None,
    name_b: str | None,
) -> None:
    """译文保真校验(D10.3;失败 = 显式错误,不写缓存)。

    - v1 模块:剥围栏 json.loads 后递归同构(键集合/数组长度/非字符串值)
    - 合盘:章节数与原文相同;两人名字在原文出现过的,译文里必须出现
    - 禁词扫描由调用方走共享 validate_interpretation(同一道)

    Raises:
        InvalidInputError: 原文自身不是该模块形状(v1 原文非 JSON 对象;
            端点在 LLM 前已前置校验,此处兜底复检)
        AIProviderError: 译文与原文不同构 / 章节数漂移 / 名字丢失
    """
    if module in V1_MODULES:
        source_parsed = _parse_v1_source_interpretation(
            module, source_interpretation)
        try:
            translated_parsed = json.loads(_strip_code_fences(translated))
        except json.JSONDecodeError as e:
            raise AIProviderError(
                f"译文非合法 JSON(module={module},疑似截断或格式违约):{e}"
            ) from e
        if not isinstance(translated_parsed, dict):
            raise AIProviderError(
                f"译文 JSON 顶层非对象(module={module};翻译指令要求同构 JSON)")
        _assert_json_structural_identity(source_parsed, translated_parsed)
        return
    if module in _TRANSLATE_COMPAT_MODULES:
        src_chapters = _count_chapter_titles(source_interpretation)
        tgt_chapters = _count_chapter_titles(translated)
        if src_chapters != tgt_chapters:
            raise AIProviderError(
                f"合盘译文章节数漂移(原文 {src_chapters} 章 → 译文 "
                f"{tgt_chapters} 章;翻译指令要求章数不变)")
        for name in (name_a, name_b):
            if name and name in source_interpretation and name not in translated:
                raise AIProviderError(
                    f"合盘译文丢失两人称呼({name!r} 在原文出现,译文中缺失;"
                    f"翻译指令要求名字原样保留)")
        return
    # 白名单(schema TRANSLATE_MODULES)外的 module 到不了这里;显式暴露而非静默跳过
    raise RuntimeError(
        f"_assert_translation_fidelity: module={module!r} 不在已实现的翻译"
        f"保真校验范围(需补实现,TRANSLATE_MODULES 与本函数失同步)")


@router.post("/api/interpret/translate", response_model=InterpretResponse)
async def interpret_translate(
    req: TranslateRequest,
    request: Request,
    current_user_id: str | None = Depends(get_current_user_id),
) -> InterpretResponse:
    """POST /api/interpret/translate — 已生成解读的跨语言翻译(D10)。

    切换语言后,已生成的深度解析(M0-M7)/ 合盘按**翻译原文**落到目标语言
    缓存键,而不是重新解读(LLM 非确定性 → 同一张盘换个语言结论可能变,
    「换语言命就变了」违背「专业不忽悠」;长文重生成成本也高)。

    流程:
    1. 目标语言 = resolve_language(与 /api/interpret 同口径);
       source == 目标 → 422
    2. source_prompt_version ≠ 当前版本 → 409 STALE_SOURCE(走正常生成)
    3. 原文长度上限(AI_MAX_OUTPUT_TOKENS × 语言系数,en 与 zh 分档)→ 422
    3.5 v1 原文形状前置校验(非 JSON 对象 → 422,不烧 LLM)
    4. 共享 _prepare_prompt_and_key:**译文写入的缓存键 = 目标语言下
       /api/interpret 会算出的键**(逐字段相等,含目标语言模板渲染出的
       prompt_hash / parent_hash / user_input_hash / language)——之后任何
       设备以目标语言请求 /api/interpret 都命中这份译文
    5. entitlement 同检(付费模块;翻译不另收费、不消耗次数)
    5.5 服务端原文防伪(P1 安全收口):译文落的是**跨用户共享键**,客户端
       自由文本不可作为内容事实源——否则知道某盘出生数据的人可向该盘的
       目标语言键投毒任意文案。要求原文逐字存在于本后端为
       (content_hash, module, 当前版本, source_language) 生成过的缓存行;
       不可核验(清库 / 换环境 / 伪造)→ 409 STALE_SOURCE,客户端走重新生成
    6. 先查后译:目标键命中 → cached=True 直接返回(不调 LLM)
    7. translate_v1 模板(按目标语言)+ 术语对注入 + 原文 → LLM(singleflight)
    8. 保真校验(v1 JSON 递归同构 / 合盘章节数+名字)+ 禁词;失败显式
       AIProviderError,**不回退原文、不静默改走重新生成、不写缓存**
    9. 写缓存 + 返回(translated_from = source_language,来源只进日志不进 DB)
    """
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()
    language = resolve_language(request)

    # 1. 同语言翻译 → 422(客户端缓存行语言判定出错时的防御)
    if req.source_language == language:
        raise InvalidInputError(
            f"source_language({req.source_language})与目标语言({language})"
            f"相同,无需翻译", request_id=request_id)

    # 2. 陈旧原文 → 409:原文来自旧 prompt,本来就该按新版本重新生成,
    #    翻译会把旧版叙事固化进新版本键空间。客户端收到后走正常
    #    /api/interpret(重生成不视为失败重试,不反复弹翻译入口)。
    current_version = PROMPT_VERSIONS.get(req.module)
    if current_version is None:
        # schema 白名单 ⊆ PROMPT_VERSIONS,这里到不了;显式暴露失同步 bug
        raise RuntimeError(
            f"module={req.module!r} 在 TRANSLATE_MODULES 但不在 PROMPT_VERSIONS"
            f"(白名单与版本表失同步,代码 bug)")
    if req.source_prompt_version != current_version:
        logger.warning(
            "interpret.translate.stale_source request_id=%s module=%s "
            "source_prompt_version=%s current=%s",
            request_id, req.module, req.source_prompt_version, current_version,
        )
        raise StaleSourceError(
            f"原文 prompt_version={req.source_prompt_version} 已过期"
            f"(当前 {current_version}),请按正常 /api/interpret 重新生成",
            request_id=request_id, content_hash=req.content_hash)

    # 3. 长度上限(防免费通用翻译器滥用,D10.1;系数按 source_language 分档)
    char_limit = _SOURCE_INTERPRETATION_CHAR_LIMITS[req.source_language]
    if len(req.source_interpretation) > char_limit:
        raise InvalidInputError(
            f"source_interpretation 长度 {len(req.source_interpretation)} 超上限"
            f" {char_limit}"
            f"(按该模块 max_tokens 与原文语言折算;疑似非本模块解读文本)",
            request_id=request_id)

    # 3.5 v1 原文形状前置校验(422 客户端输入错误):非该模块形状的原文
    # 不烧 LLM 就拒掉——保真校验(步骤 8)兜底复检,两层同 helper 同口径。
    if req.module in V1_MODULES:
        _parse_v1_source_interpretation(req.module, req.source_interpretation)

    ai_client = request.app.state.ai_client

    # 4. 共享「校验 → 翻译 → 渲染 → 算 key」(缓存键对齐的关键,见 docstring)
    prepared = _prepare_prompt_and_key(req, language, request_id, start, ai_client)
    prompt_version = prepared.prompt_version
    translated_context = prepared.translated_context
    cache_key = prepared.cache_key
    log_ctx = prepared.log_ctx
    logger.info(
        "interpret.translate.start %s source_language=%s",
        log_ctx, req.source_language,
    )

    # 5. entitlement(与 /api/interpret 完全同一道;不另收费、不消耗次数)
    await _require_entitlement(request, req, current_user_id, request_id)

    cache: InterpretationCache = request.app.state.cache

    # 5.5 服务端原文防伪(P1 安全收口,见端点 docstring):原文必须逐字
    # 存在于本后端为该盘 / 该模块 / 当前版本 / source_language 生成过的
    # 缓存行,否则翻译会把客户端伪造文本固化进跨用户共享键。
    # 不可核验 → 409 STALE_SOURCE(iOS 既有 STALE 处理 = 清提议走重新
    # 生成,不会陷入重试翻译循环);正常流不受影响——iOS 本地原文就是
    # 后端生成后逐字存档的那份,后端缓存行持久(无 TTL)。
    try:
        source_verified = await run_in_threadpool(
            cache.has_interpretation_text,
            req.content_hash, req.module, current_version,
            req.source_language, req.source_interpretation,
        )
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.translate.source_verify_failed elapsed_ms=%.1f %s "
            "error=%r", elapsed_ms, log_ctx, e,
        )
        raise InterpretationCacheError(
            f"后端原文核验读失败({type(e).__name__}): {e}") from e
    if not source_verified:
        logger.warning(
            "interpret.translate.source_unverified request_id=%s module=%s "
            "source_language=%s content_hash=%s source_len=%d",
            request_id, req.module, req.source_language, req.content_hash,
            len(req.source_interpretation),
        )
        raise StaleSourceError(
            f"原文在后端缓存不可核验(module={req.module},source_language="
            f"{req.source_language};清库/换环境后请重新生成,伪造原文不予翻译)",
            request_id=request_id, content_hash=req.content_hash)

    # 6. 先查后译(命中行的禁词/JSON 自愈与 /api/interpret 共享)
    cached_row = await _load_validated_cache_row(
        cache, cache_key, req.module, log_ctx, request_id, req.content_hash,
        start,
    )
    if cached_row is not None:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.info(
            "interpret.translate.cache_hit elapsed_ms=%.1f %s",
            elapsed_ms, log_ctx,
        )
        return InterpretResponse(
            interpretation=cached_row["interpretation"],
            prompt_version=prompt_version,
            cached=True,
            generated_at=cached_row["generated_at"],
            provider=cached_row["provider"],
            model=cached_row["model"],
            language=language,
            # 缓存行可能是他设备正常生成 / 先前翻译,同键内容等价,不区分来源
            translated_from=None,
        )

    # 7. 翻译 prompt + LLM(singleflight 按目标 cache_key 合并同 key 并发)。
    #    键加 "translate" 命名空间(2026-10-02 修复):翻译与 /api/interpret
    #    共用 llm_singleflight 且 cache_key 相同,但两边 factory 发的 prompt
    #    不同——同盘同模块并发时后到方会拿到对方的 LLM 结果(生成方拿到
    #    译文 / 翻译方拿到生成文本并被保真校验误判 503),结果还写进共享
    #    缓存键。隔离后各自只与同端点并发合并。
    translate_prompt = _render_translate_prompt(
        req.source_language, language, req.source_interpretation)
    logger.info(
        "interpret.translate.provider_called %s source_language=%s target=%s",
        log_ctx, req.source_language, language,
    )
    sf: SingleflightCoalescer = request.app.state.llm_singleflight
    try:
        translated = await sf.coalesce(
            ("translate", cache_key), lambda: ai_client.interpret(
                translate_prompt, temperature=resolve_temperature("translate"),
            ),
        )
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.translate.provider_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        e.request_id = request_id
        raise

    # 7.5 合盘后置处理(A/B 代号兜底 + 干支接地观测,与 /api/interpret 同款)
    name_a = translated_context.get("name_a") or "A"
    name_b = translated_context.get("name_b") or "B"
    if req.module in _TRANSLATE_COMPAT_MODULES:
        translated = _maybe_replace_ab_labels(translated, name_a, name_b, language)
        _log_offchart_ganzhi(translated, translated_context, log_ctx)

    # 8. 保真校验(同构/章节/名字)+ 禁词;失败显式抛错,不写缓存(D10.3)
    try:
        _assert_translation_fidelity(
            req.module, req.source_interpretation, translated, name_a, name_b)
    except AIProviderError as e:
        e.request_id = request_id
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.translate.fidelity_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise
    validate_interpretation(
        translated,
        request_id=request_id,
        content_hash=req.content_hash,
        log_ctx=log_ctx,
    )

    # 9. 写缓存(键 = 目标语言正常生成的键)+ 返回
    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        await run_in_threadpool(
            cache.set, cache_key, translated, now_iso,
        )
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.translate.cache_set_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise InterpretationCacheError(
            f"后端缓存写失败({type(e).__name__}): {e}") from e

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "interpret.translate.ok elapsed_ms=%.1f cached=False %s "
        "source_language=%s target=%s",
        elapsed_ms, log_ctx, req.source_language, language,
    )
    return InterpretResponse(
        interpretation=translated,
        prompt_version=prompt_version,
        cached=False,
        generated_at=now_iso,
        provider=ai_client.provider,
        model=ai_client.model,
        language=language,
        translated_from=req.source_language,
    )
