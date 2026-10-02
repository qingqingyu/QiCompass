"""POST /api/interpret/translate 行为测试(S6,D10.1-D10.3,2026-10-01)。

覆盖(i18n-zh-hant-plan.md §4 S6 验收项):
- **缓存键对齐**(关键):翻译落键后,以目标语言调 /api/interpret 命中
  cached=true 且内容为译文(不重新生成)
- STALE_SOURCE 409(原文旧 prompt 版本)
- 模块白名单(alias 等白名单外 → 422;daily_fortune 2026-10-01 L5/F3 扩入)
- entitlement:付费模块同检(无 → 403;有 → 200,不消耗额外次数)
- 同语言 → 422;原文超长 → 422;v1 原文非 JSON → 422
- 保真校验失败(同构/章节数/名字)→ 503 且**不写缓存**
- 先查后译:目标键命中 → cached=true,不调 LLM
- /api/interpret 响应 translated_from 恒为 null
- 术语对构建:反查冲突裁决(Seven Killings→七杀;Wu 整组剔除;未知冲突抛错)
"""

from __future__ import annotations

import json

import pytest

from app.engine.term_translations import (
    TERM_TRANSLATIONS,
    build_translation_term_pairs,
)
from app.models.interpret import TRANSLATE_MODULES
from tests.fixtures.interpret_cases import COMPATIBILITY_CONTEXT

# ---------- fixtures ----------

M0_CHART = json.dumps({
    "pillars": {"year": {"gan_zhi": "庚午", "shishen_gan": "七杀"}},
    "day_master": {"stem": "甲", "element": "木", "strength_label": "偏弱"},
}, ensure_ascii=False)

M0_ZH_JSON = json.dumps({
    "structure_fingerprint": "七杀驱动的高压结构",
    "main_axis": {"dominant": "七杀", "evidence": "年柱透七杀"},
    "core_loop": {"from": "七杀", "to": "偏财", "flow": "压力转化为产出", "n": 2},
}, ensure_ascii=False)

M0_HANT_JSON = json.dumps({
    "structure_fingerprint": "七殺驅動的高壓結構",
    "main_axis": {"dominant": "七殺", "evidence": "年柱透七殺"},
    "core_loop": {"from": "七殺", "to": "偏財", "flow": "壓力轉化為產出", "n": 2},
}, ensure_ascii=False)


def _m0_translate_payload(source_interpretation: str = M0_ZH_JSON,
                          source_language: str = "zh",
                          source_prompt_version: int = 2) -> dict:
    """zh→目标语言的 m0 翻译请求(m0 免费,无 entitlement 字段)。"""
    return {
        "content_hash": "hash-tr-m0",
        "module": "m0_structure",
        "context": {"chart": M0_CHART},
        "target_date": None,
        "source_language": source_language,
        "source_prompt_version": source_prompt_version,
        "source_interpretation": source_interpretation,
    }


def _seed_source_row(cache, payload: dict, text: str) -> None:
    """直接落一行 source_language 原文(翻译防伪前提)。

    `has_interpretation_text` 不匹配 hash 维度(见 app/ai/cache.py 注释),
    hash 列用占位值即可;version/language/content_hash/module/text 须真值。
    """
    from app.ai.cache_key import CacheKey
    cache.set(
        CacheKey(
            content_hash=payload["content_hash"],
            module=payload["module"],
            prompt_version=payload["source_prompt_version"],
            target_date=payload.get("target_date") or "",
            prompt_hash="seed-placeholder",
            provider="anthropic",
            model="mock-anthropic-model",
            parent_hash="",
            user_input_hash="",
            language=payload["source_language"],
        ),
        text,
        "2026-10-01T00:00:00+00:00",
    )


# ---------- 缓存键对齐(D10.1 核心) ----------

async def test_translate_then_interpret_hits_same_cache_key(
        interpret_client, mock_ai_client):
    """翻译写入的键 = 目标语言 /api/interpret 会算出的键(逐字段相等)。

    流程:zh 生成 → zh-hant 翻译(译文落键)→ 以 zh-hant 调 /api/interpret
    → cached=true 且内容为译文(任何设备此后都拿这份,不再生成)。
    """
    # 1. zh 正常生成(顺带验证 source 形状的真实来源)
    mock_ai_client.set_response(M0_ZH_JSON)
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-tr-m0", "module": "m0_structure",
        "context": {"chart": M0_CHART}, "target_date": None,
    })
    assert resp.status_code == 200, resp.text
    assert resp.json()["language"] == "zh"
    assert resp.json()["translated_from"] is None  # /api/interpret 恒为 null

    # 2. 翻译到 zh-hant
    mock_ai_client.set_response(M0_HANT_JSON)
    resp = await interpret_client.post(
        "/api/interpret/translate",
        json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["cached"] is False
    assert body["language"] == "zh-hant"
    assert body["translated_from"] == "zh"
    assert body["prompt_version"] == 2
    llm_calls_after_translate = mock_ai_client.call_count

    # 3. 以目标语言调 /api/interpret → 命中翻译写入的键
    resp = await interpret_client.post(
        "/api/interpret",
        json={
            "content_hash": "hash-tr-m0", "module": "m0_structure",
            "context": {"chart": M0_CHART}, "target_date": None,
        },
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["cached"] is True, "译后目标语言请求必须命中缓存(键对齐失败)"
    assert body["interpretation"] == M0_HANT_JSON
    assert mock_ai_client.call_count == llm_calls_after_translate  # 没再调 LLM

    # 4. 反向隔离:zh 键的缓存不受影响(仍是简体原文)
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-tr-m0", "module": "m0_structure",
        "context": {"chart": M0_CHART}, "target_date": None,
    })
    assert resp.json()["cached"] is True
    assert resp.json()["interpretation"] == M0_ZH_JSON


async def test_translate_cache_hit_skips_llm(
        interpret_client, mock_ai_client, tmp_cache):
    """先查后译:目标键已命中 → cached=true,不调 LLM(D10.1)。"""
    _seed_source_row(tmp_cache, _m0_translate_payload(), M0_ZH_JSON)
    mock_ai_client.set_response(M0_HANT_JSON)
    first = await interpret_client.post(
        "/api/interpret/translate", json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert first.status_code == 200 and first.json()["cached"] is False
    calls = mock_ai_client.call_count

    # 第二次翻译同 key:命中第一次的译文
    mock_ai_client.set_response("占位(不应被调用)")
    second = await interpret_client.post(
        "/api/interpret/translate", json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert second.status_code == 200, second.text
    assert second.json()["cached"] is True
    assert second.json()["interpretation"] == M0_HANT_JSON
    assert second.json()["translated_from"] is None  # 命中行来源不区分
    assert mock_ai_client.call_count == calls


# ---------- 门控:版本 / 白名单 / 语言 / 长度 ----------

async def test_stale_source_returns_409(interpret_client):
    """source_prompt_version ≠ 当前版本 → 409 STALE_SOURCE(该走重新生成)。"""
    resp = await interpret_client.post(
        "/api/interpret/translate",
        json=_m0_translate_payload(source_prompt_version=1),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 409, resp.text
    assert resp.json()["error"]["code"] == "STALE_SOURCE"


@pytest.mark.parametrize("module,extra", [
    ("bazi_deep", {}),
])
async def test_module_whitelist_rejects_non_translatable(
        interpret_client, module, extra):
    """白名单外 module(已退役散文模块)→ 422(D10.1;daily_fortune 于
    2026-10-01 L5/F3 扩入白名单,不再是 422 项;alias "compatibility"
    撞付费 user_local_id 前置校验,不在此重复覆盖)。"""
    payload = _m0_translate_payload()
    payload["module"] = module
    payload.update(extra)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 422, resp.text
    assert "不支持翻译" in str(resp.json())


def test_translate_modules_whitelist_contents():
    """白名单 = v1 M0-M7 + 合盘现役两件 + 每日运势(单一事实源断言;
    daily 扩入 = L5/F3 修订 D10 模块表,2026-10-01)。"""
    from app.models.interpret import V1_MODULES
    assert TRANSLATE_MODULES == V1_MODULES | {
        "compatibility_free", "compatibility_paid", "daily_fortune"}
    assert "compatibility" not in TRANSLATE_MODULES  # alias 不投入


async def test_same_language_returns_422(interpret_client):
    """source_language == 目标语言 → 422(客户端语言判定出错的防御)。"""
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh"},
    )
    assert resp.status_code == 422, resp.text
    assert "相同" in str(resp.json())


async def test_oversized_source_returns_422(interpret_client):
    """原文超长(语言分档上限)→ 422(防通用翻译器滥用)。"""
    from app.api.interpret import _SOURCE_INTERPRETATION_CHAR_LIMITS
    payload = _m0_translate_payload(
        source_interpretation="字" * (
            _SOURCE_INTERPRETATION_CHAR_LIMITS["zh"] + 1))
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 422, resp.text
    assert "超上限" in str(resp.json())


async def test_en_source_uses_en_char_limit(
        interpret_client, mock_ai_client, tmp_cache):
    """en 原文长度上限按 4 字符/token 折算(2026-10-02 修复):

    zh 档(×1.5=12288)对 en 长章(M1/M2/M3/M5/M7 可达 12k-16k 字符)
    会误伤 422 → en→中翻译永久不可用。本用例提交一段超过 zh 档但低于
    en 档的 en 合盘原文(散文契约,无 JSON 前置形状校验):不应在长度门
    422,而是走到防伪核验(409 = 已过长度门)。
    """
    from app.api.interpret import _SOURCE_INTERPRETATION_CHAR_LIMITS
    zh_limit = _SOURCE_INTERPRETATION_CHAR_LIMITS["zh"]
    en_limit = _SOURCE_INTERPRETATION_CHAR_LIMITS["en"]
    assert en_limit > zh_limit, "en 档必须比 zh 档宽(4 字符/token vs 1 字/token)"
    payload = _compat_translate_payload(source_interpretation="a" * (zh_limit + 100))
    payload["source_language"] = "en"
    payload["source_prompt_version"] = 4
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh"},
    )
    # 不 seed 原文行:过长度门后会停在防伪核验(409),证明长度门放行
    assert resp.status_code == 409, resp.text
    assert mock_ai_client.call_count == 0


async def test_en_source_over_en_limit_422(interpret_client):
    """en 原文超过 en 档(×4)→ 仍 422(上限的防滥用语义保留)。"""
    from app.api.interpret import _SOURCE_INTERPRETATION_CHAR_LIMITS
    payload = _m0_translate_payload(
        source_interpretation="a" * (
            _SOURCE_INTERPRETATION_CHAR_LIMITS["en"] + 1),
        source_language="en")
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh"},
    )
    assert resp.status_code == 422, resp.text
    assert "超上限" in str(resp.json())


def test_char_limits_cover_all_source_languages():
    """分档字典键 ⊇ TranslateRequest.source_language 的全部合法 Literal 值。

    字典是 2026-10-02 新引入的漂移面:加语言时只改 Literal 不补分档,
    路由层 `_SOURCE_INTERPRETATION_CHAR_LIMITS[req.source_language]` 会
    KeyError 500(而非受控 422/409)。用测试锁双侧同步(对齐
    check_term_sync / check_sku_sync 的机器护栏文化,防静默漂移)。
    """
    import typing

    from app.api.interpret import _SOURCE_INTERPRETATION_CHAR_LIMITS
    from app.models.interpret import TranslateRequest
    annotation = TranslateRequest.model_fields["source_language"].annotation
    allowed = set(typing.get_args(annotation))
    missing = allowed - set(_SOURCE_INTERPRETATION_CHAR_LIMITS)
    assert not missing, (
        f"加语言须同步 _SOURCE_INTERPRETATION_CHAR_LIMITS(缺 {missing} "
        f"→ 运行时 KeyError 500)")


async def test_v1_source_not_json_returns_422(
        interpret_client, mock_ai_client):
    """v1 module 的原文非合法 JSON → 422,且**不烧 LLM**(形状校验前置)。"""
    payload = _m0_translate_payload(source_interpretation="这不是 JSON")
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 422, resp.text
    assert mock_ai_client.call_count == 0, "客户端输入错误不得产生 provider 成本"


async def test_unverified_source_returns_409(interpret_client, mock_ai_client):
    """服务端原文防伪:后端缓存无逐字一致的原文行 → 409 STALE_SOURCE,
    不烧 LLM(防客户端伪造文本经翻译投毒跨用户共享缓存键)。"""
    forged = json.dumps({
        "structure_fingerprint": "攻击者伪造的叙事",
        "main_axis": {}, "core_loop": {},
    }, ensure_ascii=False)
    resp = await interpret_client.post(
        "/api/interpret/translate",
        json=_m0_translate_payload(source_interpretation=forged),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 409, resp.text
    assert resp.json()["error"]["code"] == "STALE_SOURCE"
    assert "不可核验" in resp.json()["error"]["message"]
    assert mock_ai_client.call_count == 0, "伪造原文不得产生 provider 成本"


async def test_source_with_surrounding_whitespace_translates(
        interpret_client, mock_ai_client, tmp_cache):
    """首尾带空白的原文照常可译(2026-10-02 修复 strip 409 死路)。

    LLM 原始输出常带尾随换行/围栏前导空白;客户端把它逐字存档并逐字回传,
    此前请求校验器 strip 后再与缓存行 SQL 逐字比对,这类真实原文永远
    核验失败 409 → 客户端反复重试、重复扣次数。seed 一行带首尾空白的
    原文,提交同文本 → 必须过防伪(200)。
    """
    raw_source = f"\n\n{M0_ZH_JSON}\n\n"
    payload = _m0_translate_payload(source_interpretation=raw_source)
    _seed_source_row(tmp_cache, payload, raw_source)
    mock_ai_client.set_response(M0_HANT_JSON)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["translated_from"] == "zh"


async def test_translate_and_generate_do_not_coalesce(
        interpret_client, mock_ai_client, tmp_cache):
    """翻译与正常生成并发同键不得合并 singleflight(2026-10-02 修复)。

    两端点共用 llm_singleflight 且目标 cache_key 相同,但 factory 发的
    prompt 不同;键未隔离时后到方拿到对方的结果串台(生成拿到译文 /
    翻译拿到生成文本还可能被保真校验误判 503)。慢 mock 制造并发窗口,
    断言两端点各自调一次 LLM 且拿到各自产物。
    """
    import asyncio

    from app.main import app
    from tests.fixtures.mock_ai import MockAIClient

    class _SlowScriptedMock(MockAIClient):
        """按 prompt 是否翻译模板分答应 + 人工延迟制造并发窗口。"""

        async def interpret(self, prompt: str, *, temperature: float = 0.6) -> str:
            await asyncio.sleep(0.05)
            self.call_count += 1
            self.last_prompt = prompt
            self.last_temperature = temperature
            # _render_translate_prompt 恒以「===== 原文结束 =====」收尾
            # (标记字面量与目标语言无关),生成模板不含
            if "原文结束" in prompt:
                return M0_HANT_JSON
            return M0_ZH_JSON

    slow = _SlowScriptedMock()
    saved_ai = app.state.ai_client
    app.state.ai_client = slow
    try:
        gen_payload = {
            "content_hash": "hash-tr-sf", "module": "m0_structure",
            "context": {"chart": M0_CHART}, "target_date": None,
        }
        tr_payload = _m0_translate_payload()
        tr_payload["content_hash"] = "hash-tr-sf"
        _seed_source_row(tmp_cache, tr_payload, M0_ZH_JSON)
        gen_resp, tr_resp = await asyncio.gather(
            interpret_client.post("/api/interpret", json=gen_payload,
                                  headers={"X-QiCompass-Lang": "zh-hant"}),
            interpret_client.post("/api/interpret/translate", json=tr_payload,
                                  headers={"X-QiCompass-Lang": "zh-hant"}),
        )
        assert gen_resp.status_code == 200, gen_resp.text
        assert tr_resp.status_code == 200, tr_resp.text
        # 生成 → 生成模板产物(简体 JSON);翻译 → 译文(繁体 JSON)
        assert gen_resp.json()["interpretation"] == M0_ZH_JSON, \
            "生成拿到翻译结果 = singleflight 串台"
        assert tr_resp.json()["interpretation"] == M0_HANT_JSON, \
            "翻译拿到生成结果 = singleflight 串台"
        assert slow.call_count == 2, "两端点应各调一次 LLM(合并 = 串台)"
    finally:
        app.state.ai_client = saved_ai


# ---------- entitlement(付费模块同检,翻译不另收费) ----------

async def test_paid_module_translate_without_entitlement_403(
        interpret_client):
    """m2_high_low 无 entitlement → 403(与 /api/interpret 同一道)。"""
    payload = _m0_translate_payload()
    payload.update({
        "module": "m2_high_low",
        "context": {
            "chart": M0_CHART, "structure_fingerprint": "七杀驱动",
            "innate": "抗压产出", "defensive": "过度自律",
        },
        "user_local_id": "user-1",
        "parent_fingerprint": "fp-m2",
    })
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 403, resp.text
    assert resp.json()["error"]["code"] == "ENTITLEMENT_NOT_FOUND"


async def test_paid_module_translate_with_entitlement_200(
        interpret_client, mock_ai_client, tmp_entitlement_store, tmp_cache):
    """m2_high_low 有 entitlement → 200(翻译不另收费、不消耗次数)。"""
    from tests.test_interpret_paid import _seed_entitlement
    _seed_entitlement(tmp_entitlement_store,
                      content_hash="hash-tr-m0", module="bazi_deep")

    src = json.dumps({"high_config": {"portrait": "输出稳定"}},
                     ensure_ascii=False)
    tgt = json.dumps({"high_config": {"portrait": "輸出穩定"}},
                     ensure_ascii=False)
    payload = _m0_translate_payload(source_interpretation=src)
    payload.update({
        "module": "m2_high_low",
        "context": {
            "chart": M0_CHART, "structure_fingerprint": "七杀驱动",
            "innate": "抗压产出", "defensive": "过度自律",
        },
        "user_local_id": "user-1",
        "parent_fingerprint": "fp-m2",
    })
    _seed_source_row(tmp_cache, payload, src)
    mock_ai_client.set_response(tgt)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["translated_from"] == "zh"


# ---------- 保真校验(D10.3:失败显式错误,不写缓存) ----------

async def test_translated_not_json_returns_503(interpret_client,
                                               mock_ai_client, tmp_cache):
    """译文非 JSON(如空文本/截断)→ 503 AI_PROVIDER_ERROR,不写缓存。"""
    _seed_source_row(tmp_cache, _m0_translate_payload(), M0_ZH_JSON)
    mock_ai_client.set_response("")
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 503, resp.text
    assert resp.json()["error"]["code"] == "AI_PROVIDER_ERROR"
    assert "非合法 JSON" in resp.json()["error"]["message"]


async def test_fidelity_failure_returns_503_and_skips_cache(
        interpret_client, mock_ai_client, tmp_cache):
    """译文改了数字/结构 → 503 AI_PROVIDER_ERROR,且缓存未写入。"""
    _seed_source_row(tmp_cache, _m0_translate_payload(), M0_ZH_JSON)
    broken = json.dumps({
        "structure_fingerprint": "七殺驅動的高壓結構",
        "main_axis": {"dominant": "七殺", "evidence": "年柱透七殺",
                      "extra_key": "擅自增写的"},
        "core_loop": {"from": "七殺", "to": "偏財", "flow": "壓力轉化為產出",
                      "n": 2},
    }, ensure_ascii=False)
    mock_ai_client.set_response(broken)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 503, resp.text
    assert resp.json()["error"]["code"] == "AI_PROVIDER_ERROR"
    assert "不同构" in resp.json()["error"]["message"]

    # 缓存未写入:以目标语言调 /api/interpret 落穿到 LLM(cached=False)
    mock_ai_client.set_response(M0_HANT_JSON)
    resp = await interpret_client.post(
        "/api/interpret",
        json={
            "content_hash": "hash-tr-m0", "module": "m0_structure",
            "context": {"chart": M0_CHART}, "target_date": None,
        },
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200
    assert resp.json()["cached"] is False, "失败译文不得入缓存"


async def test_provider_failure_propagates(interpret_client,
                                           mock_ai_client, tmp_cache):
    """LLM 输出无法通过保真校验 → 显式失败,绝不 200 回退原文。"""
    _seed_source_row(tmp_cache, _m0_translate_payload(), M0_ZH_JSON)
    mock_ai_client.set_response("随便一段非 JSON 文本")
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_m0_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 503, resp.text
    assert resp.status_code != 200


# ---------- 合盘翻译(章节 + 名字 + A/B 后置) ----------

_COMPAT_CTX = {
    "context_label": "通用",
    "name_a": "小美", "name_b": "小林",
    "gender_a": "女", "city_a": "台北", "birth_a": "1992-08-10 14:00",
    "day_master_a": "丙", "day_master_strength_a": "strong",
    "favorable_a": "土金",
    "year_a": "壬申", "month_a": "戊申", "day_a": "丙午", "hour_a": "乙未",
    "element_balance_a": "木1火3土2金2水2",
    "gender_b": "男", "city_b": "北京", "birth_b": "1990-03-05 07:20",
    "day_master_b": "甲", "day_master_strength_b": "weak",
    "favorable_b": "木火",
    "year_b": "庚午", "month_b": "己卯", "day_b": "甲子", "hour_b": "丁卯",
    "element_balance_b": "木3火2土1金1水1",
    "five_elements_assessment": "互补佳",
    "day_master_relation": "相生",
    "zodiac_match": "六合",
    "branch_harmony": "无冲无刑",
    "synced_fortune_table": "- 2026:A 同步走强",
}

_COMPAT_SRC = (
    "第一章 基础相处模式\n\n两人节奏互补。小美与小林。\n\n"
    "第二章 互补与冲突总览\n\n五行互补佳。"
)
_COMPAT_TGT = (
    "第一章 基礎相處模式\n\n兩人節奏互補。小美與小林。\n\n"
    "第二章 互補與衝突總覽\n\n五行互補佳。"
)


def _compat_translate_payload(source_interpretation: str = _COMPAT_SRC) -> dict:
    return {
        "content_hash": "hash-tr-compat",
        "module": "compatibility_free",
        "context": dict(_COMPAT_CTX),
        "target_date": None,
        "source_language": "zh",
        "source_prompt_version": 4,
        "source_interpretation": source_interpretation,
    }


async def test_compat_translate_ok_and_ab_labels_replaced(
        interpret_client, mock_ai_client, tmp_cache):
    """合盘 zh→zh-hant:章节数/名字保真通过 + standalone A/B 兜底替换。"""
    _seed_source_row(tmp_cache, _compat_translate_payload(), _COMPAT_SRC)
    # 译文里故意残留一个 standalone「B」(LLM 违约),后置处理应换成 name_b
    tgt_with_ab = _COMPAT_TGT.replace(
        "兩人節奏互補。", "兩人節奏互補,B 傾向先說結論。")
    mock_ai_client.set_response(tgt_with_ab)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_compat_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    text = resp.json()["interpretation"]
    assert "B 傾向" not in text, "standalone B 应被替换为 name_b"
    # 代号后的半角空格按既有设计吞掉(中文排版无残留空格)
    assert "小林傾向先說結論" in text
    assert "小美" in text and "小林" in text
    assert resp.json()["language"] == "zh-hant"


async def test_compat_translate_chapter_drift_503(
        interpret_client, mock_ai_client, tmp_cache):
    """译文丢章 → 503,不写缓存。"""
    _seed_source_row(tmp_cache, _compat_translate_payload(), _COMPAT_SRC)
    mock_ai_client.set_response(_COMPAT_TGT.replace(
        "第二章 互補與衝突總覽\n\n", ""))
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_compat_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 503, resp.text
    assert "章节数漂移" in resp.json()["error"]["message"]


async def test_compat_translate_lost_name_503(
        interpret_client, mock_ai_client, tmp_cache):
    """译文丢两人称呼 → 503。"""
    _seed_source_row(tmp_cache, _compat_translate_payload(), _COMPAT_SRC)
    mock_ai_client.set_response(_COMPAT_TGT.replace("小美", "她"))
    resp = await interpret_client.post(
        "/api/interpret/translate", json=_compat_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 503, resp.text
    assert "两人称呼" in resp.json()["error"]["message"]


def test_compat_context_fixture_shape():
    """共享 fixture 完整性(本文件内联 context 与 interpret_cases 同域抽查)。"""
    assert COMPATIBILITY_CONTEXT.get("context_label") in ("通用", "婚姻", "事业")


# ---------- 术语对构建(D10.2:反查冲突裁决) ----------

# ---------- 每日运势翻译(L5/F3,2026-10-01 修订 D10 模块表) ----------

_DAILY_ZH_JSON = (
    '{"headline": "静心开局", "work": "先做要紧的事。", '
    '"relationships": "话留三分。", "energy": "按自己的节奏来。", '
    '"reminder": "量力而行。"}'
)
_DAILY_HANT_JSON = (
    '{"headline": "靜心開局", "work": "先做要緊的事。", '
    '"relationships": "話留三分。", "energy": "按自己的節奏來。", '
    '"reminder": "量力而行。"}'
)


def _daily_translate_payload(
        source_interpretation: str = _DAILY_ZH_JSON,
        source_language: str = "zh",
        source_prompt_version: int = 4) -> dict:
    """zh→目标语言的 daily_fortune 翻译请求(免费模块,带 target_date——
    缓存键对齐的前提:与 iOS runInterpretation 发的 context 同源)。"""
    from tests.fixtures.interpret_cases import DAILY_FORTUNE_CONTEXT
    return {
        "content_hash": "hash-tr-daily",
        "module": "daily_fortune",
        "context": DAILY_FORTUNE_CONTEXT,
        "target_date": "2026-07-12",
        "source_language": source_language,
        "source_prompt_version": source_prompt_version,
        "source_interpretation": source_interpretation,
    }


async def test_daily_translate_then_interpret_hits_same_cache_key(
        interpret_client, mock_ai_client):
    """daily 缓存键对齐(L5/F3 核心验收):翻译落键(含 target_date 维度)
    → 以目标语言 + 同 target_date 调 /api/interpret 命中 cached=true。"""
    # 1. zh 正常生成(当天运势)
    mock_ai_client.set_response(_DAILY_ZH_JSON)
    base = {
        "content_hash": "hash-tr-daily", "module": "daily_fortune",
        "target_date": "2026-07-12",
    }
    from tests.fixtures.interpret_cases import DAILY_FORTUNE_CONTEXT
    resp = await interpret_client.post(
        "/api/interpret", json={**base, "context": DAILY_FORTUNE_CONTEXT})
    assert resp.status_code == 200, resp.text
    assert resp.json()["language"] == "zh"

    # 2. 翻译到 zh-hant(不消耗任何配额:翻译端点无 counter 概念)
    mock_ai_client.set_response(_DAILY_HANT_JSON)
    resp = await interpret_client.post(
        "/api/interpret/translate",
        json=_daily_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["cached"] is False
    assert body["language"] == "zh-hant"
    assert body["translated_from"] == "zh"
    assert body["prompt_version"] == 4
    llm_calls = mock_ai_client.call_count

    # 3. 目标语言 + 同 target_date 调 /api/interpret → 命中译文
    resp = await interpret_client.post(
        "/api/interpret",
        json={**base, "context": DAILY_FORTUNE_CONTEXT},
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["cached"] is True, "daily 译后目标语言请求必须命中(键对齐失败)"
    assert body["interpretation"] == _DAILY_HANT_JSON
    assert mock_ai_client.call_count == llm_calls  # 没再调 LLM

    # 4. 反向隔离:zh 键不受影响
    resp = await interpret_client.post(
        "/api/interpret", json={**base, "context": DAILY_FORTUNE_CONTEXT})
    assert resp.json()["cached"] is True
    assert resp.json()["interpretation"] == _DAILY_ZH_JSON


async def test_daily_source_shape_422(interpret_client, mock_ai_client,
                                      tmp_cache):
    """daily 原文形状前置校验:非五键 JSON → 422,不烧 LLM。"""
    _seed_source_row(
        tmp_cache, _daily_translate_payload(), _DAILY_ZH_JSON)
    bad_sources = [
        "一段散文,不是 JSON",
        json.dumps({"headline": "只有一键"}, ensure_ascii=False),
        json.dumps({
            "headline": "静心", "work": "做事", "relationships": "待人",
            "energy": "节奏", "reminder": "   "}, ensure_ascii=False),
    ]
    for bad in bad_sources:
        mock_ai_client.set_response(_DAILY_HANT_JSON)
        resp = await interpret_client.post(
            "/api/interpret/translate",
            json=_daily_translate_payload(source_interpretation=bad),
            headers={"X-QiCompass-Lang": "zh-hant"},
        )
        assert resp.status_code == 422, (bad, resp.text)
    assert mock_ai_client.call_count == 0, "形状不过 → 不得烧 LLM"


async def test_daily_fidelity_drift_503_and_skips_cache(
        interpret_client, mock_ai_client, tmp_cache):
    """daily 译文键漂移(五键丢一)→ 503 AI_PROVIDER_ERROR,且不写缓存。"""
    _seed_source_row(
        tmp_cache, _daily_translate_payload(), _DAILY_ZH_JSON)
    drift = json.dumps({
        "headline": "靜心開局", "work": "先做要緊的事。",
        "relationships": "話留三分。", "energy": "按自己的節奏來。",
    }, ensure_ascii=False)  # 丢 reminder
    mock_ai_client.set_response(drift)
    resp = await interpret_client.post(
        "/api/interpret/translate",
        json=_daily_translate_payload(),
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 503, resp.text
    assert resp.json()["error"]["code"] == "AI_PROVIDER_ERROR"

    # 缓存未写:目标语言 /api/interpret 落穿重新生成
    mock_ai_client.set_response(_DAILY_HANT_JSON)
    from tests.fixtures.interpret_cases import DAILY_FORTUNE_CONTEXT
    resp = await interpret_client.post(
        "/api/interpret",
        json={
            "content_hash": "hash-tr-daily", "module": "daily_fortune",
            "context": DAILY_FORTUNE_CONTEXT, "target_date": "2026-07-12",
        },
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200
    assert resp.json()["cached"] is False, "失败译文不得入缓存"


class TestBuildTranslationTermPairs:
    def test_forward_zh_to_hant_drops_identity(self):
        pairs = dict(build_translation_term_pairs("zh", "zh-hant"))
        assert pairs["七杀"] == "七殺"
        assert pairs["长生"] == "長生"
        assert all(s != t for s, t in pairs.items())  # identity 对不上表

    def test_reverse_en_to_zh_canonical_override(self):
        """Seven Killings → 七杀(偏官同义,canonical 裁决)。"""
        pairs = dict(build_translation_term_pairs("en", "zh"))
        assert pairs["Seven Killings"] == "七杀"
        assert "偏官" not in pairs.values()

    def test_reverse_en_homograph_group_dropped(self):
        """"Wu" 同为 戊/午 无调拼音 → 整组剔除(上下文自行判断)。"""
        pairs = dict(build_translation_term_pairs("en", "zh-hant"))
        assert "Wu" not in pairs

    def test_unknown_reverse_conflict_raises(self, monkeypatch):
        """未裁决的反查冲突 → 显式 KeyError(不静默取任一)。"""
        monkeypatch.setitem(TERM_TRANSLATIONS["zh-hant"], "测试甲", "測試甲")
        monkeypatch.setitem(TERM_TRANSLATIONS["zh-hant"], "测试乙", "測試乙")
        monkeypatch.setitem(TERM_TRANSLATIONS["en"], "测试甲", "Colliding")
        monkeypatch.setitem(TERM_TRANSLATIONS["en"], "测试乙", "Colliding")
        with pytest.raises(KeyError, match="Colliding"):
            build_translation_term_pairs("en", "zh")

    def test_same_language_rejected(self):
        with pytest.raises(ValueError, match="相同"):
            build_translation_term_pairs("zh", "zh")
