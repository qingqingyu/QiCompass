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
  (每请求一次的主渲染路径;**翻译防伪的源键核验除外**——见下)
- /api/interpret/translate 的源键核验(M1-M7 链重建 walk 按分支×版本重渲染 /
  链尾源键渲染 / M0+daily 源重渲染)虽然同为纯 CPU,但一次请求可含
  多次渲染且模板加载带磁盘读(_load_template 无缓存),2026-10-07 起
  全部经 run_in_threadpool(dd0e5dd)
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
from collections.abc import AsyncIterator
from contextlib import aclosing
from datetime import datetime, timezone
from typing import Any, Final, NamedTuple, NoReturn

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..ai.cache import InterpretationCache
from ..ai.cache_key import CacheKey
from ..ai.forbidden_words import scan as scan_forbidden_words
from ..ai.forbidden_words import validate_interpretation
from ..ai.prompts import (
    COMPATIBILITY_MODULES,
    PROMPT_VERSIONS,
    REQUIRED_FIELDS,
    V1_CHAIN_PRODUCER,
    canonicalize_v1_chain_fields,
    render_prompt,
    validate_context,
)
from ..ai.singleflight import SingleflightCoalescer
from ..auth.dependencies import get_current_user_id
from ..config import (
    AI_MAX_OUTPUT_TOKENS, FREE_DAILY_LIMIT, PAID_DAILY_LIMIT,
    REFUND_DAILY_LIMIT, resolve_temperature,
)
from ..context_binding import verify_interpret_context
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
    QuotaExceededError,
    StaleSourceError,
)
from ..models.interpret import (
    InterpretRequest,
    InterpretResponse,
    PAID_MODULES,
    TranslateRequest,
    V1_CHILDREN_MODULES,
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


# ---------- v1 链式字段:上游链映射(2026-10-07 翻译防伪回归修复) ----------

# 链式字段 → 产出模块的映射表(V1_CHAIN_PRODUCER)与字段规范化
# (canonicalize_v1_chain_fields)自 2026-10-08 起收口在 app/ai/prompts.py
# (render_prompt 内联规范化,直调渲染的 evalkit/spike 与线上字节对齐),
# 本文件经 import 消费,不再各持一份。

# M1-M7 的源键重建依赖(拓扑序:被依赖者在前)。镜像 iOS
# ModuleDefinitions.swift dependencies;m7 模板不读 chart 但其请求仍带
# chart(DeepAnalysisOrchestrator.buildV1Request 恒注入)且 parent_fingerprint
# 取自 M0 产出,故 m0 也在依赖内。
_V1_SOURCE_WALK_DEPS: Final[dict[str, tuple[str, ...]]] = {
    "m1_talent": ("m0_structure",),
    "m2_high_low": ("m0_structure", "m1_talent"),
    "m3_system": ("m0_structure",),
    "m4_health": ("m0_structure",),
    "m5_wealth": ("m0_structure", "m1_talent", "m3_system"),
    "m6_dynamics": ("m0_structure", "m1_talent", "m2_high_low"),
    "m7_manual": ("m0_structure", "m1_talent", "m2_high_low", "m3_system",
                  "m6_dynamics"),
}


def _canonical_chain_value(value: object) -> str | None:
    """上游输出值 → context 字符串形态(与 iOS 序列化口径对齐)。

    - str(标量链字段,如 structure_fingerprint / one_leverage):原样
      (iOS `as? String` 直取)
    - dict / list:canonical JSON(sort_keys + 紧凑分隔符 + ensure_ascii=False)
      ——iOS 侧是 JSONSerialization 的紧凑输出,键序/空白与 dict 内部顺序
      相关;服务端统一 canonical 形态,使 prompt_hash 只取决于字段的
      **语义内容**,与两端序列化字节形式解耦(这正是本修复的前提)
    - 其他标量(数字/布尔):iOS 端 JSONSerialization 顶层非容器会抛错、
      字段不会被设置,此处返回 None 跳过,镜像之
    """
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, ensure_ascii=False,
                          separators=(",", ":"))
    return None


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
    # v1 链式字段先规范化(2026-10-07 回归修复):dict/list 链字段的
    # prompt_hash 取 canonical 形态,与客户端序列化字节形式解耦——翻译
    # 防伪的源键重建(interpret_translate)才能从上游缓存行精确复原生成键。
    # 一次性影响:M1-M7 既有后端缓存键含旧序列化形态,部署后自然失效重生成
    # (iOS 本地缓存键不含 prompt_hash,不受影响)。
    try:
        translated_context = canonicalize_v1_chain_fields(
            req.module,
            translate_context(req.context, language, req.module),
        )
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
) -> dict[str, Any] | None:
    """付费 module 的 entitlement 检查(/api/interpret 与 /translate 同一道)。

    权益与语言无关:翻译不另收费、不消耗任何次数(D10.1)。
    返回命中的 entitlement 记录(十七轮 #4):付费配额桶键取**记录自身
    的 owner**(user_id 优先,空则 user_local_id)——get_active 是
    「user_id 优先、user_local_id 兜底」的双轨匹配,同一条 ulid 购买的
    记录可被 N 个登录账号命中,若桶键用请求身份(current_user_id or
    ulid),切账号即可叠开 N 个付费桶;按记录 owner 分桶,同一笔购买
    恒定共享一个桶。免费 module 返回 None(调用方不消费)。
    """
    if req.module not in PAID_MODULES:
        return None
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
    return entitlement


def _paid_bucket_owner(
    entitlement: dict[str, Any] | None,
    req: InterpretRequest, current_user_id: str | None,
) -> str:
    """付费桶键的 owner token(十七轮 #4 + 十八轮 #4):命中的 entitlement
    记录自身主体,请求身份只作兜底(免费 module / 极端缺记录时不应触达)。

    返回值带 id 类型前缀(`user:` / `ulid:`):user_id 与 user_local_id
    同为客户端/服务端各自铸造的 UUID 字符串,共用一个键空间——不加区分
    时 `paid:ent:{uuid}` 理论上可被两种身份形态撞键(概率 ~0 但格式上
    不可证伪)。前缀是**纯键空间切分**,不改变分桶语义:同一笔记录恒定
    同一个桶。旧格式 `paid:ent:{裸uuid}` 计数行按 day 键自然过期,无迁移
    (同上次付费桶维度变更的口径)。"""
    if entitlement:
        if entitlement.get("user_id"):
            return f"user:{entitlement['user_id']}"
        if entitlement.get("user_local_id"):
            return f"ulid:{entitlement['user_local_id']}"
    if current_user_id:
        return f"user:{current_user_id}"
    return f"ulid:{req.user_local_id}"


def _normalize_client_ip(host: str) -> str:
    """匿名 bucket 的 IP 归一化:IPv6 收敛到 /64 前缀(2026-10-07 review)。

    IPv6 用户有 2^64 地址空间,单地址作 bucket 可换地址无限刷免费额度;
    收敛到 /64(运营商会分给一个子网的典型粒度)封死此通道。IPv4 原样。

    IPv4 映射形态的 IPv6 地址(`::ffff:a.b.c.d`)必须先解出内层 IPv4
    (2026-10-08 修复):双栈 socket / 部分反代把 IPv4 对端写成映射形态,
    若直接按 IPv6 /64 归并,`::ffff:*` 全部落到 `::/64` 同一个网络地址
    ——**全站 IPv4 匿名用户被并进一个配额桶**(实测 `::ffff:1.2.3.4` 与
    `::ffff:5.6.7.8` 均归并为 `::/64`)。解出后按普通 IPv4 单地址分桶。
    非 IP 字符串(测试桩 / 异常环境)原样返回,与旧行为一致。
    """
    if ":" not in host:
        return host
    import ipaddress
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return host
    if isinstance(addr, ipaddress.IPv6Address):
        mapped = addr.ipv4_mapped
        if mapped is not None:
            return str(mapped)
        return str(ipaddress.IPv6Network(f"{host}/64", strict=False))
    # IPv6 字面量之外能解析成 IPv4 的(理论不可达:无冒号已在顶部返回;
    # 带冒号的 IPv4 不存在)——按解析结果原样返回,行为可预测
    return str(addr)


def _free_quota_bucket(request: Request, current_user_id: str | None) -> str:
    """免费配额 bucket:登录按 user_id,匿名按客户端 IP(user_local_id 客户端
    可伪造,不作 bucket;IP 经 _normalize_client_ip 归一化)。"""
    if current_user_id:
        return f"user:{current_user_id}"
    host = request.client.host if request.client else "unknown"
    return f"ip:{_normalize_client_ip(host)}"


def _quota_tier(req: InterpretRequest) -> tuple[str, int]:
    """配额分档(2026-10-08 第十四轮拍板:付费不再豁免)。

    免费/付费**分档计数**互不挤兑(维度差异见 _quota_bucket:免费 =
    user_id | 归一化 IP,付费 = entitlement 主体);付费上限
    PAID_DAILY_LIMIT 拦的是 M4/M5 换输入无限烧 LLM 的脚本滥用,
    不影响任何正常单用户 usage。
    """
    if req.module in PAID_MODULES:
        return "paid", PAID_DAILY_LIMIT
    return "free", FREE_DAILY_LIMIT


def _quota_bucket(
    request: Request, req: InterpretRequest, current_user_id: str | None,
    paid_owner: str | None = None,
) -> str:
    """配额 bucket:免费 = (user_id | 归一化 IP) 无前缀旧格式;付费 = 购买主体。

    付费桶改按 entitlement 主体(2026-10-08 十六轮 neirong #4):登录
    user_id、匿名 user_local_id。旧形态 paid:{user:|ip:} 复用免费桶维度,
    匿名分支按 IP 计——CGNAT/运营商 NAT 后的付费用户共享 PAID_DAILY_LIMIT
    (100 < 免费桶 150 倒挂),换 IP(移动网络重连)即重置,既拦不住滥用
    又误伤正常付费。改按购买主体:付费调用必先过 _require_entitlement
    (get_active 按 user_local_id / user_id 匹配权益),伪造 user_local_id
    无权益 403 在前,轮换身份 = 丢权益,桶不可白嫖轮换。残留:restore
    重绑新 user_local_id 可开新桶,但每桶都要一轮 Apple 校验往返,比旧
    IP 自由轮换严格(记录于 docs/维持不修决策评审-2026-10-08.md 附七)。
    免费桶保持无前缀旧格式(既有计数行不失效);付费旧 paid:{ip:|user:}
    计数行按 day 键自然过期,无迁移。
    十七轮 #4 收口:owner 取**命中的 entitlement 记录自身主体**
    (`_paid_bucket_owner`)——get_active 双轨匹配(user_id 优先、ulid
    兜底)下,同一笔匿名购买可被 N 个登录账号命中,按请求身份分桶 =
    切账号叠开 N 个付费桶;按记录 owner 分桶,同一笔购买恒定一个桶。
    十八轮 #4:owner token 统一由 `_paid_bucket_owner` 铸造(带 user:/
    ulid: 类型前缀,防两种 UUID 键空间撞键),本函数不再自行拼接裸 id;
    兜底路径同经该函数,全链路单一格式化点。
    """
    tier, _ = _quota_tier(req)
    if tier == "paid":
        owner = paid_owner or _paid_bucket_owner(None, req, current_user_id)
        return f"paid:ent:{owner}"
    return _free_quota_bucket(request, current_user_id)


async def _quota_exhausted(
    request: Request, req: InterpretRequest,
    current_user_id: str | None, day: str, paid_owner: str | None = None,
) -> bool:
    """配额 peek(只读不消费;十四轮外评 #4;免费/付费分档)。

    翻译端点在「目标缓存 miss 之后、v1 链走查(分支×版本重渲染,CPU 最重)之前」
    用:达限 bucket 直接 429,堵住「持 token 换链字段值 → 目标键必 miss →
    无限重放走查烧 CPU」的放大通道(走查本身不计配额,原「缓存命中即免
    走查」的假设挡不住主动 miss)。缓存命中路径在 peek 之前返回,不受影响。

    分档(十五轮接缝修正):付费不再豁免 peek——「付费 factory 内仍有
    PAID_DAILY_LIMIT 硬闸」的原注释只界定了 **LLM 烧次**,不界定制表重放:
    付费桶耗尽后持 entitlement 者换链字段值重放,每次仍跑完整走查(有界/
    模块但请求无界),与已关闭的免费洞同构;peek 与 enforce 同 tier 同桶
    (见 _quota_tier/_quota_bucket),合法达限用户的目标缓存命中不受影响
    (命中先返回)。
    """
    from ..quota.store import FreeLLMQuotaStore
    store: FreeLLMQuotaStore = request.app.state.free_quota_store
    tier, limit = _quota_tier(req)
    bucket = _quota_bucket(request, req, current_user_id, paid_owner)
    count = await run_in_threadpool(
        store.get_count, bucket=bucket, day=day)
    return count >= limit


def _raise_quota_exceeded(content_hash: str, *, tier: str, limit: int) -> NoReturn:
    """达限 429(文案/错误面单一来源,免费/付费分档)。

    factory 内 enforce 扣费失败与 translate 走查前 peek 达限(十四轮外评
    #4)共用同一错误面——客户端只认一种 QUOTA_EXCEEDED,字面量必须永不
    漂移,故收口在此。分档(第十四轮付费上限拍板):付费也有独立上限,
    免费 tier 的「付费内容不受此限」已失真删除。
    """
    if tier == "paid":
        message = f"今日解读生成次数已达服务端每日上限({limit}/日),明日再来"
    else:
        message = f"今日免费解读生成次数已达服务端上限({limit}/日),明日再来"
    raise QuotaExceededError(message, content_hash=content_hash)


async def _enforce_daily_quota(
    request: Request,
    req: InterpretRequest,
    current_user_id: str | None,
    day: str,
    paid_owner: str | None = None,
) -> None:
    """真烧 LLM 前的每日服务端配额(2026-10-07 匿名滥用收口;2026-10-08
    第十四轮付费收口:付费从豁免改为独立分桶计数)。

    只在缓存未命中、即将调用 provider 的路径上执行(缓存命中零成本不计)。
    bucket:登录按 user_id,匿名按 IP(user_local_id 客户端可伪造,不作
    bucket);免费/付费分桶(见 _quota_bucket)。
    达限 → QuotaExceededError(429),不静默降级。

    `day` 由调用方(生成 factory)一次性算出并同时传给 enforce/refund——
    避免扣与退各自取「现在」导致 UTC 跨午夜时退款打到 day N+1 的空行,
    泄漏 1 次计数(2026-10-07 double review)。
    """
    from ..quota.store import FreeLLMQuotaStore
    store: FreeLLMQuotaStore = request.app.state.free_quota_store
    tier, limit = _quota_tier(req)
    bucket = _quota_bucket(request, req, current_user_id, paid_owner)
    ok = await run_in_threadpool(
        store.try_consume, bucket=bucket, day=day, limit=limit)
    if not ok:
        logger.warning(
            "interpret.quota_exceeded tier=%s bucket=%s day=%s limit=%d "
            "module=%s content_hash=%s",
            tier, bucket, day, limit, req.module, req.content_hash)
        _raise_quota_exceeded(req.content_hash, tier=tier, limit=limit)


async def _refund_daily_quota(
    request: Request,
    req: InterpretRequest,
    current_user_id: str | None,
    day: str,
    paid_owner: str | None = None,
) -> None:
    """配额退款(compensating action;2026-10-08 拍板:分类退+防刷上限;
    第十四轮起免费/付费同款,按各自 tier 桶退)。

    分类:provider 抛错(服务商故障)与 LLM 正常返回后的**非用户过错**
    失败(v1 JSON 契约/截断、翻译保真)退;禁词命中等用户输入可触发的
    失败不退(伪造触发禁词的输入若退款 = 免费烧 LLM 不扣额的通道)。
    防刷:退款按 (bucket, day) 计数,超过 REFUND_DAILY_LIMIT 封顶不退。
    退款失败只记日志不遮蔽主错误(退款是补偿动作,非主路径;对齐
    DeepAnalysisOrchestrator userLink 降级记日志的先例)。

    `day` 由调用方一次性算出(与 enforce 同一 day,防跨午夜退款打空行)。
    """
    from ..quota.store import FreeLLMQuotaStore
    store: FreeLLMQuotaStore = request.app.state.free_quota_store
    bucket = _quota_bucket(request, req, current_user_id, paid_owner)
    try:
        refunded = await run_in_threadpool(
            store.try_refund, bucket=bucket, day=day, limit=REFUND_DAILY_LIMIT)
    except Exception as e:
        logger.exception(
            "interpret.quota_refund_failed bucket=%s day=%s error=%r",
            bucket, day, e,
        )
        return
    if not refunded:
        logger.warning(
            "interpret.quota_refund_capped bucket=%s day=%s "
            "refund_limit=%d — 当日退款次数已达上限,本次不退(防刷封顶)",
            bucket, day, REFUND_DAILY_LIMIT,
        )


# 退款豁免模块(2026-10-08 十四轮外评 #3;十五轮接缝扩面):分类退款拍板
# (2026-10-08:契约/截断/保真退,禁词不退)的前提是「失败属服务商侧、
# 非用户过错」。以下模块的失败可被用户输入**故意触发**,退款 = 每日至多
# REFUND_DAILY_LIMIT 次免费烧 LLM 的通道(免费桶)/付费桶白嫖(付费
# 退款随第十四轮付费上限拍板激活,滥用面同款),直接豁免:
# - 契约失败退豁免 = 全部 context 含客户端自由文本的 v1 模块(m1-m7):
#   m1-m3/m6/m7 的链式字段是客户端序列化文本,m4 的 current_concern /
#   m5 的 assets_summary/preference 是自由文本用户输入——同一注入向量
#   (「忽略 JSON 格式要求」),tier 无关。**十五轮接缝修正**:原案只列
#   m1_talent(彼时付费不退款,豁免免费面即够);付费退款激活后 m2-m7
#   同向量重开,与附五 #4 给 compatibility_paid 补保真豁免同理扩面。
#   截断不在此列——截断在 provider client 层已显式报错
#   (stop_reason=max_tokens),走 4.1 的 provider 异常退款路径,不受本
#   豁免影响。
# - 翻译保真失败退豁免 = 合盘两拆分模块:name_a/name_b 是用户输入,取
#   中文常用单字(如「的」)时 zh→en 翻译保真校验**必定**失败(该字在
#   zh 原文作为语法粒子必然出现,en 译文必然不含此汉字)。
# m0_structure/daily_fortune 的 context 全部服务端确定性派生(chart 由
# token 绑定+根行核验、日期固定格式),契约/保真失败不可注入触发,
# 退款保留。
_REFUND_CONTRACT_EXEMPT_MODULES: Final[frozenset[str]] = frozenset({
    "m1_talent", "m2_high_low", "m3_system", "m4_health",
    "m5_wealth", "m6_dynamics", "m7_manual",
})
_REFUND_FIDELITY_EXEMPT_MODULES: Final[frozenset[str]] = frozenset({
    "compatibility_free",
    # 十五轮 #4 扩面:付费盘称呼同样客户端可控(name_a/b 不在绑定集),
    # 「的」类必败称呼对 compatibility_paid 同样成立,滥用面 = 付费桶
    # 退款额度(每日 ≤REFUND_DAILY_LIMIT 次真烧 LLM)。
    "compatibility_paid",
})


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

    # 2.2 context_token 验签(2026-10-07 P0 收口,一刀切:免费+付费)。
    # context 核心字段(四柱/喜忌/日主强度等盘身)必须与排盘端点签发的
    # token 一致——「买一次盘给任意命盘生成付费内容」的通道在此关闭;
    # 翻译端点同闸(见 interpret_translate),否则伪造原文投毒共享键关不死。
    # 置于 _prepare 之后:形状非法的 context 先吃 422(客户端契约错误优先
    # 暴露),验签用 raw context(绑定字段与语言无关);仍在 entitlement /
    # 缓存 / LLM 之前,安全序不变。
    verify_interpret_context(
        req.context_token, module=req.module, content_hash=req.content_hash,
        context=req.context,
        target_date_iso=(req.target_date.isoformat()
                         if req.target_date else None),
    )
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
    entitlement = await _require_entitlement(
        request, req, current_user_id, request_id)
    paid_owner = _paid_bucket_owner(entitlement, req, current_user_id)

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
    # 3.7 每日配额(2026-10-07 匿名滥用收口;2026-10-08 第十四轮付费收口):
    #     仅对真烧 LLM 的调用计数(缓存命中已在上方返回);免费/付费分桶
    #     分档(付费从豁免改为 PAID_DAILY_LIMIT 独立计数,M4/M5 换输入
    #     无限烧的通道收口)。达限 429 不降级。
    #     扣/退移入 singleflight factory(2026-10-07 review):只有真正发
    #     LLM 的 leader 扣 1 次(并发同 key 的 follower 共享结果不重复扣);
    #     provider 抛错退回(服务商故障期间重试不烧光当日额度)。
    # v1 prompt 系统:按 module 分级 temperature(M0-M2=0.3 稳结构,M3-M7=0.6
    # 重质感,老模块=0.6 向后兼容);Stage 2 已铺基础设施,此处接入路由
    #
    # 后置处理(4.2)/ 契约校验(4.4)/ 禁词(4.5)/ 写缓存(5)一并收进
    # factory(2026-10-08 外评 #8):此前它们在 handler 侧 coalesce 之后执行,
    # 创建者请求被取消(客户端断连)时 shield 保护的 factory 照常烧完 LLM、
    # 扣掉配额,但结果随 handler 取消被丢弃——重试 = 再烧一次 LLM 再扣一次
    # 额度。收进 factory 后无论调用方存亡,成品必经验证并落缓存。
    logger.info("interpret.provider_called %s", log_ctx)
    sf: SingleflightCoalescer = request.app.state.llm_singleflight
    # CacheKey 是 frozen dataclass,自动 hashable,直接作 singleflight dict key
    # (语义对齐:同 cache key 的并发 LLM 调用合并为一次)
    sf_key = cache_key
    temperature = resolve_temperature(req.module)

    async def _generate() -> tuple[str, str]:

        # 已知取舍(2026-10-08 review 点名,记录不修):配额在 singleflight
        # factory 内只按 **leader 的身份** 扣——并发同 key 的 follower 共享
        # 结果,自己的 bucket 不扣。即:leader 超额 → 同 key 的有额用户一起
        # 429;leader 有额 → 超额用户搭车白得一次。触发前提是不同用户同时
        # 对同一 (盘, module, 语言) 发起请求(同 content_hash 共享键),实际
        # 并发窗口极窄;按身份分别扣需要把配额闸移出 factory 在 coalesce 外
        # 逐请求执行,会失去「并发重复请求只烧一次 LLM」的合并价值,得不偿失。
        # iOS 侧 429 已映射达限态(QUOTA_EXCEEDED → dailyLimitReached),
        # 误伤用户有明确出口。
        day = datetime.now(timezone.utc).date().isoformat()
        await _enforce_daily_quota(
            request, req, current_user_id, day, paid_owner=paid_owner)
        try:
            interpretation = await ai_client.interpret(
                prompt, temperature=temperature)
        except Exception as e:
            # 只在真烧过 LLM 的路径退回(配额已扣);QuotaExceededError 在
            # 扣费前抛出,不会走到这里。CancelledError 是 BaseException,
            # 不进 except Exception,不误退。LLM 正常返回后的失败见 4.4/4.5
            # 的分类退款(2026-10-08 拍板:契约/截断/保真退,禁词不退)。
            # factory 内留痕(十四轮外评 #6):生成已收进共享任务,创建者
            # 断连且无跟随者时异常只被 singleflight done_callback 检索、
            # 无人日志——本行是该场景下共享失败的唯一锚点;消费侧
            # provider_failed 日志保留(标记谁收到了它)。
            logger.exception(
                "interpret.factory_provider_failed %s error=%r",
                log_ctx, e,
            )
            await _refund_daily_quota(
                request, req, current_user_id, day, paid_owner=paid_owner)
            raise

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
        # 真机 m1_talent 实证)。daily_fortune v4 五键契约同门(2026-09-30):
        # 违约不进双层缓存,防 iOS 端「Retry 拿回同一段坏文本」的缓存毒化循环。
        try:
            _validate_v1_module_json(req.module, interpretation)
            _validate_daily_fortune_json(req.module, interpretation)
        except AIProviderError as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.error(
                "interpret.v1_invalid_json elapsed_ms=%.1f %s error=%s",
                elapsed_ms, log_ctx, e,
            )
            # 分类退款(2026-10-08 拍板):契约/截断失败属服务商侧非用户过错
            # (09-27 max_tokens 截断事故实证主因)——校验已收进 factory,
            # 天然只由真正扣款的 leader 执行(follower 共享结果未扣款,退了
            # 会把自己 bucket 其他请求的计数减 1);受退款日上限保护。
            # 豁免(十四轮外评 #3;十五轮接缝扩面 m1-m7):链式字段/m4/m5
            # 自由文本是客户端注入向量,可故意触发契约失败,退款 = 免费/
            # 付费桶白烧 LLM 通道(截断走 4.1 provider 异常路径不受影响)。
            # 退款按 tier 桶(第十四轮付费上限):免费/付费各自封顶。
            if req.module not in _REFUND_CONTRACT_EXEMPT_MODULES:
                await _refund_daily_quota(
                request, req, current_user_id, day, paid_owner=paid_owner)
            raise

        # 4.5 禁词扫描(LLM 输出守卫,US-COMP-04)
        # 命中即拦截:不替换文本,不写缓存,不返回原文,直接抛错让客户端进入
        # error 态。分类退款口径(2026-10-08 拍板):禁词命中**不退**——用户
        # 可构造能触发禁词的输入,退款 = 免费烧 LLM 不扣额的通道(退款日上限
        # 只兜底,此处直接不进退款类)。
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
        return interpretation, now_iso

    try:
        interpretation, now_iso = await sf.coalesce(sf_key, _generate)
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.provider_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        # request_id 只在消费侧逐请求打(十四轮外评 #7):factory 内不戳
        # 共享异常对象(否则跟随者拿到创建者的 id);本行 → raise → 响应
        # 序列化之间无 await 点,并发消费者各自覆盖不影响各自响应。
        e.request_id = request_id
        raise
    # 非预期异常(AttributeError/TypeError 等代码 bug)不包装,
    # 向上抛由全局 handler 处理为 500,避免用 503 掩盖代码缺陷

    # 6. 返回(后置处理 4.2 / 契约校验 4.4 / 禁词 4.5 / 写缓存 5 已收进
    # factory,2026-10-08 外评 #8:创建者请求被取消时 shield 保护的 factory
    # 仍会完整跑完「LLM → 校验 → 落缓存」,重试命中缓存而不再烧 LLM/扣额度)
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


# ---------- v1 M1-M7 翻译防伪:源语言上游链重建(2026-10-07 回归修复) ----------

def _extract_v1_output(text: str) -> dict | None:
    """缓存行原文 → 解析后的 JSON 对象(v1 输出契约;坏行/非对象 → None)。

    坏行(截断时代遗留)对链重建不可用,返回 None 由调用方跳过该行——
    这不是吞错:行级可用性是搜索空间剪枝,最终核验失败仍显式 409。
    """
    try:
        parsed = json.loads(_strip_code_fences(text))
    except (json.JSONDecodeError, RecursionError):
        # RecursionError 与 JSONDecodeError 同款按坏行剪枝(行是服务端
        # 生成,现实风险低;不捕获会 500,防御与 _canonicalize 一致)。
        return None
    return parsed if isinstance(parsed, dict) else None


def _render_v1_upstream_prompt_hash(
    module: str, chart: str, verified_fields: dict[str, str],
    language: str, prompt_version: int,
) -> str | None:
    """按已核验上游字段 + 请求 chart 重渲染上游模块 prompt,返回 prompt_hash。

    与行生成路径(_prepare_prompt_and_key)同序:先 translate_context(源
    语言非 zh 时 chart 会被 _translate_deep_context 翻译——跳过它则重渲染
    hash 与 en/zh-hant 行的生成 hash 永不相等,合法翻译恒 409),再渲染。
    链字段规范化由 render_prompt 内联完成(2026-10-08 外评 #9 收口,单一
    决定点)——本函数不再显式规范化,避免走查热路径双重规范化(幂等但
    白做一半,十四轮外评 #9)。
    context = REQUIRED_FIELDS[module] 中可由链提供的字段 + chart(上游
    m1/m2/m3/m6 的模板只消费这两类;用户输入字段 m4/m5 不在链上)。
    字段缺失(上游输出缺 key)/渲染失败 → None(该行不可核验,剪枝)。
    """
    required = REQUIRED_FIELDS[module]
    context: dict[str, str] = {}
    for name in required:
        if name == "chart":
            context["chart"] = chart
        elif name in verified_fields:
            context[name] = verified_fields[name]
        else:
            return None
    try:
        translated = translate_context(context, language, module)
        rendered = render_prompt(
            module, translated, language=language,
            prompt_version=prompt_version)
    except (InvalidInputError, KeyError, FileNotFoundError, ValueError):
        # ChartJSONDecodeError(ValueError 子类,chart 非法 JSON)/术语
        # KeyError(翻译表缺)等:行生成时同样会失败、行不存在,此处按
        # 「该行不可核验」剪枝(→ 409),不伪装成基础设施故障。
        return None
    return hashlib.sha256(rendered.encode("utf-8")).hexdigest()



# 走查重渲染总预算(2026-10-08 十六轮外评 #3):provider/model 变体回溯
# 会让重渲染按分支数相乘,预算给全函数单次请求封顶(**非 M0 版本渲染 ×
# 分支前缀 + 叶子源键渲染**各 -1,耗尽即停,走查按 False 落 409 → STALE
# 自愈)。M0 根渲染**不进预算**(十七轮起 main 惯例:按行集版本每请求每
# 版本至多一次、不受分支数放大,由 _V1_CHAIN_MAX_VERSION_PROBES 封顶——
# 见 _verify_v1_chain_translation_source 内「M0 根渲染不进渲染预算」注释;
# 本注释原写「M0 根渲染各 -1」与实现不符,十八轮外评更正)。
# 2048 高于任何合法链需求(≤5 层 × 个位数版本 × 个位数变体 + 分支叶子
# 渲染),同时把旧实现的最坏面压下来——变体回溯不扩大 CPU 面。预算边界
# 语义:耗尽时刚枚举完的分支叶子核验被跳过(先查后退,不赊账)——硬预算
# 必须切掉某人,只影响变体洪水下的 409 落点,合法链(预算用量个位数)
# 不可达(十八轮外评定性,维持)。
_V1_CHAIN_WALK_RENDER_BUDGET: Final[int] = 2048
# 走查版本探查上限(2026-10-08 十六轮 neirong #3,精确主键查找):每层候选
# 枚举按「行集内 distinct prompt_version」降序逐版本算期望 hash,渲染次数
# 与行数解耦——同版本量产的变体行既挤不掉真行(无窗口),也放大不了重渲染
# CPU。上限是防御性封顶:行版本 ∈ PROMPT_VERSIONS 历史,攻击者造不出新
# 版本号(生成只按当前版本写行)。
_V1_CHAIN_MAX_VERSION_PROBES: Final[int] = 8


def _match_exact_v1_rows(
    rows: list[tuple[CacheKey, str, str]], version: int,
    expected_hash: str, parent_hash: str,
) -> list[tuple[CacheKey, str, str]]:
    """(prompt_version, prompt_hash, parent_hash, user_input_hash="") 四元
    精确匹配行集(2026-10-08 十六轮 neirong #3,精确主键查找),按
    generated_at 降序返回(镜像旧偏好序,「分支首序 = 旧首匹配序」不变)。

    匹配与行序/行数/落库时间无关:同版本量产的异 hash 变体行(注入形态)
    期望 hash 对不上,自然出局——旧「偏好序 + 8 行窗口 + 逐行比对」的
    驱逐残留(≥8 条更新的同 parent 注入行可暂时压出真行 → 409)结构性
    关闭;同 (版本, hash) 的 provider/model 变体行(PK 十维含
    provider/model,同键异文本并存,十六轮 houduan #3)**全收集**,
    交由 `_iter_v1_chain_branches` 按链字段贡献去重回溯。
    """
    matched = [
        item for item in rows
        if item[0].prompt_version == version
        and item[0].prompt_hash == expected_hash
        and item[0].parent_hash == parent_hash
        and item[0].user_input_hash == ""
    ]
    matched.sort(key=lambda item: item[2], reverse=True)
    return matched


async def _iter_v1_chain_branches(
    upstreams: tuple[str, ...],
    rows_by_module: dict[str, list[tuple[CacheKey, str, str]]],
    chart: str,
    source_language: str,
    parent_hash: str,
    base_verified: dict[str, str],
    render_budget: list[int],
) -> AsyncIterator[dict[str, str]]:
    """非 M0 上游链的核验分支惰性枚举(2026-10-08 十六轮外评 #3:变体回溯;
    同日双 review 建议收口:边生成边核验)。

    缓存主键十维含 provider/model:换 provider/模型重生成后,同(版本,
    parent_hash, prompt_hash)的新旧行**并存**——prompt 相同 → prompt_hash
    相同,LLM 文本不同 → 提取的链字段不同。旧实现每层只提交首个 hash 匹配
    行(偏好序 = generated_at 降序,恒先提交新变体),链在中段分叉时,
    分叉点之下的行/叶子按新变体字段重渲染的键与旧链行对不上 → 持旧文翻译
    的合法用户恒 409(「同版本同 context 的行被 PK 去重」的旧注释不成立,
    PK 含 provider/model)。M0 根层回溯救不了中段分叉——两条链共享同一根。

    本函数逐层枚举**全部** hash 匹配行,按「该行贡献的链字段(canonical
    形态)」去重后 DFS 展开;分支首序 = 旧实现的逐层首匹配序(无变体
    并存时行为不变)。组合爆炸由 render_budget 封顶——注入行要进分支必须
    先产出合法 JSON 落库(真烧 LLM),真实变体每层 ≤2-3,合法链远触不到
    预算。

    **异步生成器(边生成边核验)**:调用方对每条分支立即做叶子源键精确
    比对、首条通过即停止迭代——①无变体请求只枚举首条路径(每层 ~1 次
    重渲染,与旧「逐层首匹配」实现同开销,不吃「先列完全部分支」的
    每层 ≤8 版本探查);②后段分支的枚举渲染不再先于首条核验消耗预算
    (「列完全部才核验」形态下,首条合法分支可能被枚举阶段饿死在预算
    外 → 409)。

    候选枚举(2026-10-08 十六轮 neirong #3 撞车消解融合)= 按行集 distinct
    版本降序逐版本重渲染期望 hash,`_match_exact_v1_rows` 四元精确匹配
    **全收集**:渲染次数 = 版本数(与行数解耦,变体刷行不再放大重渲染
    CPU、也不再能挤掉真行——无窗口,驱逐残留关闭);同 (版本, hash) 的
    provider/model 变体行全数进入(回溯语义不变)。每次版本渲染 -1
    render_budget。坏行(输出不可解析)剪枝但不阻断同层其它变体——旧
    实现首匹配行坏即整链弃,此处顺带修复。
    """
    # parent/user_input 预过滤 + 版本清单(确定性维度,十七轮 #7):版本枚举
    # 前剪掉必不匹配的行。按 (upstream, parent_hash) 记忆化(十八轮外评
    # #3):parent_hash 在单根内恒定(= sha256(M0 fp)),旧实现每个分支
    # 前缀都重跑一遍全行集过滤/排序(变体洪水下 O(n) 列表推导占事件循环);
    # 记忆化后每 (层, 根) 只算一次,且计算本身放线程池(与
    # _match_exact_v1_rows 同款收口,不再占事件循环)。
    prefilter_cache: dict[
        tuple[str, str],
        tuple[list[tuple[CacheKey, str, str]], list[int]],
    ] = {}

    def _prefilter_rows(
        module_rows: list[tuple[CacheKey, str, str]], parent: str,
    ) -> tuple[list[tuple[CacheKey, str, str]], list[int]]:
        up_rows = [
            item for item in module_rows
            if item[0].parent_hash == parent
            and item[0].user_input_hash == ""
        ]
        up_versions = sorted(
            {key.prompt_version for key, _, _ in up_rows}, reverse=True)
        return up_rows, up_versions

    async def collect(
        idx: int, verified: dict[str, str],
    ) -> AsyncIterator[dict[str, str]]:
        if idx == len(upstreams):
            yield verified
            return
        upstream = upstreams[idx]
        seen_contributions: set[str] = set()
        prefilter_key = (upstream, parent_hash)
        if prefilter_key not in prefilter_cache:
            prefilter_cache[prefilter_key] = await run_in_threadpool(
                _prefilter_rows,
                rows_by_module.get(upstream) or [], parent_hash)
        up_rows, up_versions = prefilter_cache[prefilter_key]
        for up_version in up_versions[:_V1_CHAIN_MAX_VERSION_PROBES]:
            if render_budget[0] <= 0:
                break
            render_budget[0] -= 1
            # 渲染是纯 CPU(translate_context + 模板 format + sha256),
            # 放线程池防阻塞事件循环(2026-10-07 review 收尾:行读取已在
            # 池,渲染同款)。期望 hash 按分支前缀的 verified 字段计算,
            # 分支间 verified 不同 → 渲染次数 = 版本数 × 分支前缀数,
            # 由 render_budget 统一封顶。
            expected_hash = await run_in_threadpool(
                _render_v1_upstream_prompt_hash,
                upstream, chart, verified, source_language, up_version)
            if expected_hash is None:
                continue
            # 行集匹配(过滤+排序)放线程池:flooded 行集下不让 O(n)
            # 比较占事件循环(匹配行 ≤ 变体数,JSON 解析留循环内)
            for _, text, _ in await run_in_threadpool(
                    _match_exact_v1_rows,
                    up_rows, up_version, expected_hash, parent_hash):
                upstream_out = _extract_v1_output(text)
                if upstream_out is None:
                    continue  # 坏行剪枝:不产生字段,不阻断同层其它候选
                contribution: dict[str, str] = {}
                for name, producer in V1_CHAIN_PRODUCER.items():
                    if producer == upstream and name in upstream_out:
                        value = _canonical_chain_value(
                            upstream_out.get(name))
                        if value is not None:
                            contribution[name] = value
                signature = json.dumps(
                    contribution, sort_keys=True, ensure_ascii=False)
                if signature in seen_contributions:
                    continue  # 同贡献变体(重生成输出巧合一致)不重复展开
                seen_contributions.add(signature)
                merged = dict(verified)
                merged.update(contribution)
                # 内层递归生成器显式 aclosing(十八轮外评 #4):顶层消费方
                # 在首叶命中后 break 时,GeneratorExit 只打到最外层 yield,
                # 内层生成器靠 GC 异步回收——现在无 finally 无实害,后续
                # 在 collect 内加清理逻辑(如预算回滚 finally)时会静默
                # 不执行。确定性关闭与顶层(调用方 aclosing)同款。
                async with aclosing(collect(idx + 1, merged)) as inner:
                    async for branch in inner:
                        yield branch

    async for branch in collect(0, base_verified):
        yield branch


async def _verify_v1_chain_translation_source(
    request: Request,
    req: TranslateRequest,
    source_language: str,
    source_interpretation: str,
    target_date_iso: str | None,
    current_version: int,
    request_id: str,
    start: float,
) -> bool:
    """v1 M1-M7 翻译原文防伪:源语言上游链递归核验 + 完整源键精确比对。

    背景(2026-10-07 回归,9958cf1 引入):D10.4 下 iOS 翻译 M1-M7 携带
    **目标语言**链式字段(译后上游输出即时覆盖 v1ChainFields),原文却由
    源语言链字段生成——按请求 context 源语言重渲染算出的 prompt_hash /
    parent_hash 永远对不上,合法翻译恒 409。改为从缓存**重建**源键:

    1. 按 (content_hash, module, source_language) 枚举上游行。M0 行作链根,
       且须先过**根行核验**(第十五轮 #2):行自身 prompt_hash 与「请求
       chart 按行自身版本重渲染」逐字相等——token 验签保证解析内容等价
       (重复键已拒),根行核验保证序列化字节一致,「行恒真」双层成立,
       变体刷行(解析等价、字节不同的 chart)在此出局。
    2. 逐个非 M0 上游行:parent_hash 须等于 sha256(M0 fp) + user_input_hash
       须为空,且用「已核验上游字段 + 请求 chart」按**行自身版本**重渲染的
       prompt_hash 与行实际键逐字相等——注入链字段(如伪造 main_axis)生成
       的行落在注入键上,与真实链重建的键永不相等,在此被排除。行数上限
       无行窗口/探查上限(十七轮 #2 起按版本精确匹配,M0 根腿同款),
       不存在「截断/窗口随机砍掉合法行」的形态。同
       (版本, parent, prompt_hash) 的 provider/model 变体行(换模型重生成
       后并存,文本不同)逐层**全收集**并按链字段贡献去重回溯(十六轮
       #3)——只取首匹配会把新变体字段提交给旧链叶子,合法翻译恒 409;
       组合由走查渲染总预算封顶(_V1_CHAIN_WALK_RENDER_BUDGET);分支惰性
       流出 + 单分支叶子校验失败仅跳过该分支(十七轮 #2/#3,详见
       _iter_v1_chain_branches docstring 与叶子循环注释)。
    3. 全链核验后,以「源语言上游字段(canonical 形态)+ 请求 chart + 请求
       用户输入(m4/m5,随请求回传保键对齐)」构建源 context,经
       _prepare_prompt_and_key(与生成同一代码路径,含链字段规范化)算出
       完整源键,has_interpretation_exact 逐字核验原文。

    上游行缺失/坏行(清库、换环境、旧序列化形态行)→ False → 409
    STALE_SOURCE(iOS 既有降级路径:该章转目标语言重新生成,不卡死)。

    已知取舍(2026-10-08 外评 #2,接受不修):重渲染用的是**当前请求**的
    chart,而 chart 含 current_luck / current_year 等时变字段(build_v1_chart)
    ——用户跨年(或重排盘刷新时点)后,既有 M1-M7 行的键由旧 chart 驱动,
    与当前 chart 重建的键不相等 → 409 → 该章按目标语言重新生成。影响每年
    至多一次/每次重排一次,且重排后 iOS 链本就重算;按「宁可重生成不可
    放松防伪」接受。
    """
    cache: InterpretationCache = request.app.state.cache
    deps = _V1_SOURCE_WALK_DEPS[req.module]
    chart = req.context.get("chart")
    if not isinstance(chart, str):
        # m1-m6 的 chart 是 REQUIRED(schema 422 已拦);m7 的 chart 由 iOS
        # 恒注入但契约上可选——缺失即无法重渲染上游,不可核验。
        return False

    rows_by_module: dict[str, list[tuple[CacheKey, str, str]]] = {}
    for m in deps:
        try:
            rows = await run_in_threadpool(
                cache.get_module_rows, req.content_hash, m, source_language)
        except Exception as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.exception(
                "interpret.translate.chain_walk_rows_failed elapsed_ms=%.1f "
                "request_id=%s module=%s upstream=%s error=%r",
                elapsed_ms, request_id, req.module, m, e,
            )
            raise InterpretationCacheError(
                f"后端原文核验读失败({type(e).__name__}): {e}") from e
        # 全量行入库,parent 过滤 + 偏好序 + 截断推迟到知晓 parent_hash 的
        # 循环内做(十四轮外评 #1:截断先于过滤 + fetch 序随机 = 注入行可
        # 凭 hash 运气占满窗口挤掉真行)。取行后一次性按 generated_at 降序
        # 预排(十七轮外评 #5b):下游消费方(M0 根循环 / _iter_v1_chain_
        # branches 的 _prefilter_rows / _match_exact_v1_rows)共享同一有序
        # 输入,递归内每次调用的重排序退化为 Timsort 已序快路径;偏好序
        # 语义不变(排序键与消费方契约一致)。
        rows_by_module[m] = sorted(
            rows, key=lambda item: item[2], reverse=True)

    # M0 根腿(十七轮外评 #2 重做:精确主键查找,删 128 行探查上限)——
    # 期望 hash 按「行集 distinct 版本降序」逐版本重渲染一次,行集内四元
    # 精确匹配(_match_exact_v1_rows;M0 无 parent 维度,parent_hash="")。
    # 「M0 行恒真」= token 验签(内容等价,重复键已拒)+ 字节核验(行键与
    # 重渲染逐字相等)双层成立:变体行期望 hash 对不上自然出局,真根与
    # 行数/行序无关。旧形态(枚举行 + 128 探查上限)在 ≥128 条同版本变体
    # 行下真根恒在窗口外被跳过——neirong 十七轮补齐;同 (版本, hash) 的
    # provider/model 变体根行全收集(不同文本 → 不同 fingerprint,逐个
    # 作根尝试)。走查总量由 _V1_CHAIN_WALK_RENDER_BUDGET 统一封顶。
    m0_rows = rows_by_module.get("m0_structure") or []
    render_budget = [_V1_CHAIN_WALK_RENDER_BUDGET]
    non_m0_deps = tuple(
        m for m in deps if m != "m0_structure")
    m0_versions = sorted(
        {key.prompt_version for key, _, _ in m0_rows}, reverse=True)
    # M0 根渲染**不进渲染预算**(main 惯例,预算锁钉死):根渲染按版本每
    # 请求至多一次、不受分支数放大,由 _V1_CHAIN_MAX_VERSION_PROBES 封顶;
    # 预算只盖「分支乘法」面(非 M0 版本渲染 × 分支前缀 + 叶子渲染)
    for m0_version in m0_versions[:_V1_CHAIN_MAX_VERSION_PROBES]:
        m0_expected = await run_in_threadpool(
            _render_v1_upstream_prompt_hash,
            "m0_structure", chart, {}, source_language, m0_version,
        )
        if m0_expected is None:
            continue
        for _, m0_text, _ in await run_in_threadpool(
                _match_exact_v1_rows,
                m0_rows, m0_version, m0_expected, ""):
            m0_out = _extract_v1_output(m0_text)
            fingerprint = (
                m0_out.get("structure_fingerprint") if m0_out else None)
            if not isinstance(fingerprint, str) or not fingerprint:
                continue  # 坏根行剪枝(M0 输出缺 fingerprint)
            parent_hash = _hash_parent_fingerprint(fingerprint)
            verified: dict[str, str] = {"structure_fingerprint": fingerprint}
            for name in ("main_axis", "core_loop"):
                value = _canonical_chain_value(
                    m0_out.get(name)) if m0_out else None
                if value is not None:
                    verified[name] = value

            # 非 M0 上游:逐层枚举全部 hash 匹配行(变体回溯,十六轮 #3),
            # **异步生成器边生成边核验**——首条通过即停止迭代(aclosing 显式
            # 关闭挂起的生成器):无变体时只枚举首条路径,后段分支的枚举渲染
            # 不先于首条核验吃预算。
            # 每条核验分支各做一次完整源键精确比对;首分支 = 旧实现的逐层
            # 首匹配序,无变体并存的链行为不变。叶子源键渲染与枚举重渲染同级别
            # CPU(translate_context + render + sha256),进同一渲染预算——分支数
            # 最坏 8^4 量级,不封顶则预算只盖住枚举半边、总渲染超旧实现最坏面
            # (three-check 2026-10-08 第十六轮 R1)。
            async with aclosing(_iter_v1_chain_branches(
                    non_m0_deps, rows_by_module, chart, source_language,
                    parent_hash, verified, render_budget)) as branches:
                async for branch_verified in branches:
                    if render_budget[0] <= 0:
                        break
                    render_budget[0] -= 1
                    # 源键 = 与生成同一代码路径(_prepare_prompt_and_key,含规范化 +
                    # user_input_hash),链字段/parent_fingerprint 换成源语言已核验值。
                    source_context = dict(req.context)
                    for name in V1_CHAIN_PRODUCER:
                        if name in branch_verified:
                            source_context[name] = branch_verified[name]
                    source_req = req.model_copy(update={
                        "context": source_context,
                        "parent_fingerprint": fingerprint,
                    })
                    # 纯 CPU(校验 + 渲染 + hash),放线程池(2026-10-07 review 收尾,
                    # 与行读取/版本重渲染同款;源键渲染是本函数最重的一步)。
                    try:
                        source_prepared = await run_in_threadpool(
                            _prepare_prompt_and_key,
                            source_req, source_language, request_id, start,
                            request.app.state.ai_client)
                    except InvalidInputError as e:
                        # 该分支的链字段值过不了 context 校验(十七轮外评 #2):输出
                        # 字段长度在**生成侧**从不校验(上限只拦下游模块的 context),
                        # 变体 LLM 输出的超长字段(如 5000 字 one_leverage)可随分支
                        # 进叶子的 validate_context(对额外 key 全量长度扫描)抛
                        # InvalidInputError——该分支不可能重建出任何真实生成键,跳过
                        # 续试下一分支(→ 409 自愈路径保留;否则单个毒化变体把整个
                        # 走查钉死在 42x,iOS 既有 STALE 重生成不触发,且回溯走不到
                        # 后面的合法分支)。其它异常族(KeyError/FileNotFoundError 等
                        # 基建/配置错)与分支内容无关,仍上抛——伪装成 409 会掩盖真故障。
                        elapsed_ms = (time.perf_counter() - start) * 1000
                        logger.warning(
                            "interpret.translate.chain_branch_invalid "
                            "elapsed_ms=%.1f request_id=%s module=%s error=%r",
                            elapsed_ms, request_id, req.module, e,
                        )
                        continue
                    try:
                        source_verified = await run_in_threadpool(
                            cache.has_interpretation_exact,
                            req.content_hash, req.module, current_version,
                            source_language, source_interpretation,
                            source_prepared.cache_key.prompt_hash,
                            parent_hash,
                            source_prepared.cache_key.user_input_hash,
                            target_date_iso,
                        )
                    except Exception as e:
                        elapsed_ms = (time.perf_counter() - start) * 1000
                        logger.exception(
                            "interpret.translate.source_verify_failed elapsed_ms=%.1f "
                            "%s error=%r", elapsed_ms, source_prepared.log_ctx, e,
                        )
                        raise InterpretationCacheError(
                            f"后端原文核验读失败({type(e).__name__}): {e}") from e
                    if source_verified:
                        return True
    return False


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


def _parse_daily_source_interpretation(source_interpretation: str) -> dict:
    """daily_fortune 客户端原文的形状校验(L5/F3,翻译白名单扩入 daily)。

    与 `_parse_v1_source_interpretation` 同定位:端点在烧 LLM 之前调用,
    非五键 JSON 对象 → 422(客户端输入错误);`_assert_translation_fidelity`
    的 daily 分支复用本解析(与译文同构比对)。
    """
    try:
        parsed = json.loads(_strip_code_fences(source_interpretation))
    except json.JSONDecodeError as e:
        raise InvalidInputError(
            f"source_interpretation 不是 daily_fortune 形状的合法 JSON"
            f"({e};v4 契约为五键对象)") from e
    if not isinstance(parsed, dict):
        raise InvalidInputError(
            "source_interpretation JSON 顶层非对象(module=daily_fortune,"
            "v4 契约为五键对象)")
    bad = [
        k for k in _DAILY_FORTUNE_INSIGHT_KEYS
        if not isinstance(parsed.get(k), str) or not parsed[k].strip()
    ]
    if bad:
        raise InvalidInputError(
            f"source_interpretation 五键残缺或非字符串"
            f"(缺失/空值: {', '.join(bad)})")
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
    if module == "daily_fortune":
        # L5/F3(2026-10-01):daily v4 五键 JSON 同构(键集合相等,字符串值
        # 允许变——翻译本体);同构之外再跑五键非空校验(防空串译文,
        # 与 /api/interpret 的 _validate_daily_fortune_json 同口径)。
        source_parsed = _parse_daily_source_interpretation(source_interpretation)
        try:
            translated_parsed = json.loads(_strip_code_fences(translated))
        except json.JSONDecodeError as e:
            raise AIProviderError(
                f"译文非合法 JSON(module=daily_fortune,疑似截断或格式违约):{e}"
            ) from e
        if not isinstance(translated_parsed, dict):
            raise AIProviderError(
                "译文 JSON 顶层非对象(module=daily_fortune;"
                "翻译指令要求同构 JSON)")
        _assert_json_structural_identity(source_parsed, translated_parsed)
        _validate_daily_fortune_json(module, translated)
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

    切换语言后,已生成的深度解析(M0-M7)/ 合盘 / 每日运势(L5/F3,
    2026-10-01 扩入)按**翻译原文**落到目标语言缓存键,而不是重新解读
    (LLM 非确定性 → 同一张盘换个语言结论可能变,「换语言命就变了」违背
    「专业不忽悠」;每日运势另有硬约束:重生成会扣每日次数,次数耗尽时
    切语言当天一段新语言解读都看不到)。

    流程:
    1. 目标语言 = resolve_language(与 /api/interpret 同口径);
       source == 目标 → 422
    2. source_prompt_version ≠ 当前版本 → 409 STALE_SOURCE(走正常生成)
    3. 原文长度上限(按 source_language 分档系数,en 与 zh 系不同)→ 422
    3.5 原文形状前置校验(v1 / daily:非该模块形状 JSON → 422,不烧 LLM;
       daily 请求必须带 target_date——缓存键对齐的前提)
    4. 共享 _prepare_prompt_and_key:**译文写入的缓存键 = 目标语言下
       /api/interpret 会算出的键**(逐字段相等,含目标语言模板渲染出的
       prompt_hash / parent_hash / user_input_hash / language)——之后任何
       设备以目标语言请求 /api/interpret 都命中这份译文
    5. entitlement 同检(付费模块;翻译不另收费、不消耗次数)
    5.4 先查后译(2026-10-08 外评 #3 前置到防伪之前):目标键命中 →
        cached=True 直接返回(不调 LLM、不走链式源核验——命中行写入时已过
        全量校验,token+entitlement 已拦住未授权读取);防伪通过后步骤 6
        同道再查一次(仅剩并发窗口落盘的译文可命中,免烧一次 LLM)
    5.5 服务端原文防伪(P1 安全收口):译文落的是**跨用户共享键**,客户端
       自由文本不可作为内容事实源——否则知道某盘出生数据的人可向该盘的
       目标语言键投毒任意文案。要求原文逐字存在于本后端为
       (content_hash, module, 当前版本, source_language) 生成过的缓存行;
       不可核验(清库 / 换环境 / 伪造)→ 409 STALE_SOURCE,客户端走重新生成
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

    # 3.5 原文形状前置校验(422 客户端输入错误):非该模块形状的原文
    # 不烧 LLM 就拒掉——保真校验(步骤 8)兜底复检,两层同 helper 同口径。
    if req.module in V1_MODULES:
        _parse_v1_source_interpretation(req.module, req.source_interpretation)
    elif req.module == "daily_fortune":
        _parse_daily_source_interpretation(req.source_interpretation)

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

    # 4.2 context_token 验签(2026-10-07 P0 收口,与 /api/interpret 同一道):
    # 翻译写跨用户共享键,context 盘身必须与 token 一致——「受害者 hash +
    # 自己生成的原文 + 受害者 context」投毒目标语言键的通道依赖此闸关闭。
    # 置于 _prepare 之后(同 /api/interpret:形状 422 优先),entitlement 之前。
    verify_interpret_context(
        req.context_token, module=req.module, content_hash=req.content_hash,
        context=req.context,
        target_date_iso=(req.target_date.isoformat()
                         if req.target_date else None),
    )

    # 5. entitlement(与 /api/interpret 完全同一道;不另收费、不消耗次数)
    entitlement = await _require_entitlement(
        request, req, current_user_id, request_id)
    paid_owner = _paid_bucket_owner(entitlement, req, current_user_id)

    cache: InterpretationCache = request.app.state.cache

    async def _cached_hit_response() -> InterpretResponse | None:
        """目标键缓存命中 → cached=True 响应(D10.1 共享,5.4 与步骤 6 同一道)。

        命中行可能是他设备正常生成 / 先前翻译,同键内容等价,不区分来源
        (translated_from=None,来源只进日志不进 DB)。未命中 / 中毒行已删
        落穿 → None。禁词/JSON 契约自愈由 _load_validated_cache_row 承担。
        """
        cached_row = await _load_validated_cache_row(
            cache, cache_key, req.module, log_ctx, request_id, req.content_hash,
            start,
        )
        if cached_row is None:
            return None
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
            translated_from=None,
        )

    # 5.4 先查后译,提前到原文防伪**之前**(2026-10-08 外评 #3):v1 M1-M7 的
    # 链式源核验要按分支×版本重渲染上游(CPU 最重的一步),目标语言已有缓存
    # 时纯属白走——且持有 token 者可反复请求同一叶子模块把走查当 CPU 放大器。
    # 安全性:目标缓存行的内容在**写入时**已经过当时的生成/翻译全量校验,
    # 本请求又已过 token 验签(盘身一致)+ entitlement(付费门),直接返回
    # 不引入新内容面。
    # 注:「命中即免走查,重放也打不出成本」的原注释不成立(十四轮外评 #4):
    # 目标键含客户端可控的链式字段值,每换一个值必 miss → 走查照样跑——
    # 故 5.45 对免费模块补配额 peek 闸,达限 bucket 连走查都不进。
    hit = await _cached_hit_response()
    if hit is not None:
        return hit

    # 5.45 配额 peek 闸(十四轮外评 #4;十五轮接缝修正扩到付费档):走查
    #(5.5)不烧 LLM 原本不计配额,但达限 bucket 换链字段值重放 = 无限 CPU;
    # peek 只读不消费,真烧 LLM 的扣计数仍在 factory 内(leader 一次)。
    # 付费不再豁免 peek:「factory 内 PAID_DAILY_LIMIT 硬闸」只界 定 LLM
    # 烧次,付费桶耗尽后的走查重放仍是免费 CPU——与免费洞同构,peek 与
    # enforce 同 tier 同桶。达限 429 与 factory 内 429 同错误面,客户端既有
    # 429 处理接管;缓存命中在 peek 之前返回,合法达限用户命中不受影响。
    day = datetime.now(timezone.utc).date().isoformat()
    tier, limit = _quota_tier(req)
    if await _quota_exhausted(
            request, req, current_user_id, day, paid_owner=paid_owner):
        logger.warning(
            "interpret.translate.quota_peek_exceeded tier=%s request_id=%s "
            "module=%s content_hash=%s",
            tier, request_id, req.module, req.content_hash,
        )
        _raise_quota_exceeded(req.content_hash, tier=tier, limit=limit)

    # 5.5 服务端原文防伪(P1 安全收口,见端点 docstring):原文必须逐字
    # 存在于本后端为该盘 / 该模块 / 当前版本 / source_language 生成过的
    # 缓存行,否则翻译会把客户端伪造文本固化进跨用户共享键。
    # 不可核验 → 409 STALE_SOURCE(iOS 既有 STALE 处理 = 清提议走重新
    # 生成,不会陷入重试翻译循环);正常流不受影响——iOS 本地原文就是
    # 后端生成后逐字存档的那份,后端缓存行持久(无 TTL)。
    #
    # 分支口径(2026-10-07 回归修复后):
    # - 合盘:name_a/name_b 随语言本地化(Compatibility.selfReferenceYou
    #   你/you),服务端算不出源语言 name 值,保留宽松文本核验(单独记风险)。
    # - v1 M1-M7:D10.4 下请求携带**目标语言**链式字段,源键不可由请求
    #   context 重渲染(9958cf1 如此做 → 合法翻译恒 409 回归);改为从缓存
    #   按上游链递归核验后精确重建源键(_verify_v1_chain_translation_source)
    #   ——链字段注入生成的行落在注入键上,与真实链重建的键永不相等,
    #   投毒通道保持关死。
    # - v1 M0 / daily:context 全部确定性(M0 仅 chart,daily 的 date 固定
    #   中文格式),按源语言重渲染即原文生成键,精确比对。
    # target_date 一并进防伪(2026-10-02):daily_fortune 不比对日期会让
    # 昨天的原文通过核验、译文写进今天的共享键;schema 层
    # target_date_matches_module 已保证 daily 请求必带(缺 → 422,不放行)。
    target_date_iso = req.target_date.isoformat() if req.target_date else None
    if req.module in _TRANSLATE_COMPAT_MODULES:
        try:
            source_verified = await run_in_threadpool(
                cache.has_interpretation_text,
                req.content_hash, req.module, current_version,
                req.source_language, req.source_interpretation,
                target_date_iso,
            )
        except Exception as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.exception(
                "interpret.translate.source_verify_failed elapsed_ms=%.1f %s "
                "error=%r", elapsed_ms, log_ctx, e,
            )
            raise InterpretationCacheError(
                f"后端原文核验读失败({type(e).__name__}): {e}") from e
    elif req.module in V1_CHILDREN_MODULES:
        source_verified = await _verify_v1_chain_translation_source(
            request, req, req.source_language, req.source_interpretation,
            target_date_iso, current_version, request_id, start)
    else:
        # v1 M0 / daily:按源语言重渲染得完整源缓存键(prompt_hash/
        # parent_hash/user_input_hash)。重渲染的 422/500 语义与
        # /api/interpret 同源,原样上抛不包装为缓存错误(源 context 本应
        # 合法,违例即客户端/配置错误,不该伪装成基础设施故障)。
        # 纯 CPU,放线程池防阻塞事件循环(2026-10-07 review;M1-M7 链
        # 重建侧 _verify_v1_chain_translation_source 同款)。
        source_prepared = await run_in_threadpool(
            _prepare_prompt_and_key, req, req.source_language,
            request_id, start, ai_client)
        try:
            source_verified = await run_in_threadpool(
                cache.has_interpretation_exact,
                req.content_hash, req.module, source_prepared.prompt_version,
                req.source_language, req.source_interpretation,
                source_prepared.cache_key.prompt_hash,
                source_prepared.cache_key.parent_hash,
                source_prepared.cache_key.user_input_hash,
                target_date_iso,
            )
        except Exception as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.exception(
                "interpret.translate.source_verify_failed elapsed_ms=%.1f %s "
                "error=%r", elapsed_ms, source_prepared.log_ctx, e,
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

    # 6. 先查后译(与 5.4 同一道,非冗余):5.4 miss 到此处之间隔着原文
    # 防伪(纯读不写),另一并发请求(同键翻译/生成)恰在此窗口落盘时,
    # 此处命中可免烧一次 LLM——这是 5.4 前置后本检查仅剩的存在价值,
    # 语义与 D10.1「译文落目标键后任何设备直接命中」一致。
    hit = await _cached_hit_response()
    if hit is not None:
        return hit

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
    # 每日配额(与 /api/interpret 同一道,免费/付费分桶分档):真烧 LLM 的
    # 翻译计数(付费翻译同计 paid 桶——源文须先落缓存行,翻译侧消耗有界,
    # 计数只为护栏口径统一)。
    # 扣/退移入 singleflight factory(同 /api/interpret 的 2026-10-07 review
    # 收口:leader 扣一次、provider 抛错退回)。
    # 后置处理(7.5)/ 保真校验(8)/ 写缓存(9)一并收进 factory(2026-10-08
    # 外评 #8):此前的结构里创建者请求被取消(客户端断连)时 shield 保护的
    # factory 任务照常烧完 LLM、扣掉配额,但校验+写缓存在 handler 侧随请求
    # 一起被取消——结果丢弃,重试 = 再烧一次 LLM 再扣一次额度。收进 factory
    # 后无论调用方存亡,成品必经验证并落缓存;退款按 2026-10-08 拍板的
    # 分类口径(provider 抛错/保真失败退,禁词不退,均受退款日上限保护,
    # 见 factory 内注释)。
    sf: SingleflightCoalescer = request.app.state.llm_singleflight

    async def _generate_translation() -> tuple[str, str]:
        day = datetime.now(timezone.utc).date().isoformat()
        # paid_owner 必传(十八轮外评 #1):漏传时 enforce 扣「请求者身份」桶,
        # 而 peek(5.45)与两处 refund 都在「权益记录主体」桶——登录账号翻译
        # 匿名购买的盘时,退款打到另一个空桶 no-op(请求者桶白丢 1 次),
        # 且翻译用量永远碰不到 peek 所查的桶(切账号叠桶的口子在翻译路
        # 没关上)。扣/查/退三处同桶由回归测试锁定。
        await _enforce_daily_quota(
            request, req, current_user_id, day, paid_owner=paid_owner)
        try:
            translated = await ai_client.interpret(
                translate_prompt, temperature=resolve_temperature("translate"),
            )
        except Exception as e:
            # factory 内留痕(十四轮外评 #6,同 /api/interpret 4.1):创建者
            # 断连且无跟随者时异常只被 done_callback 检索、无人日志。
            logger.exception(
                "interpret.translate.factory_provider_failed %s error=%r",
                log_ctx, e,
            )
            await _refund_daily_quota(
                request, req, current_user_id, day, paid_owner=paid_owner)
            raise

        # 7.5 合盘后置处理(A/B 代号兜底 + 干支接地观测,与 /api/interpret 同款)
        name_a = translated_context.get("name_a") or "A"
        name_b = translated_context.get("name_b") or "B"
        if req.module in _TRANSLATE_COMPAT_MODULES:
            translated = _maybe_replace_ab_labels(
                translated, name_a, name_b, language)
            _log_offchart_ganzhi(translated, translated_context, log_ctx)

        # 8. 保真校验(同构/章节/名字)+ 禁词;失败显式抛错,不写缓存(D10.3)
        try:
            _assert_translation_fidelity(
                req.module, req.source_interpretation, translated,
                name_a, name_b)
        except AIProviderError as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.error(
                "interpret.translate.fidelity_failed elapsed_ms=%.1f %s error=%s",
                elapsed_ms, log_ctx, e,
            )
            # 分类退款(2026-10-08 拍板;十四轮 #3 豁免 + 十五轮 #4 扩面):
            # v1/daily 的源文经链走查/精确键核验为缓存原文,保真失败 =
            # 服务商侧非用户过错,退;合盘豁免不退——name_a/name_b 是用户
            # 输入、不在 token 绑定集,中文常用单字名(如「的」)可确定性
            # 触发保真失败(zh 原文必现、en 译文必无),退款 = 免费烧 LLM
            # 通道。compatibility_paid 同样豁免(十五轮 #4:付费盘称呼同
            # 样客户端可控,滥用面 = 付费桶退款额度)。校验已收进 factory,
            # 天然只由真正扣款的 leader 执行;退款受日上限保护。
            if req.module not in _REFUND_FIDELITY_EXEMPT_MODULES:
                await _refund_daily_quota(
                request, req, current_user_id, day, paid_owner=paid_owner)
            raise
        # 禁词不退(2026-10-08 拍板分类口径:用户输入可触发的失败退款
        # = 免费烧 LLM 通道;同 /api/interpret 4.5)
        validate_interpretation(
            translated,
            request_id=request_id,
            content_hash=req.content_hash,
            log_ctx=log_ctx,
        )

        # 9. 写缓存(键 = 目标语言正常生成的键)
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
        return translated, now_iso

    try:
        translated, now_iso = await sf.coalesce(
            ("translate", cache_key), _generate_translation,
        )
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.translate.provider_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        e.request_id = request_id
        raise

    # 7.5 / 8 / 9(后置处理/保真校验/写缓存)已收进 factory,见上方注释;
    # 下方直接用 factory 产出的 (translated, now_iso) 返回
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
