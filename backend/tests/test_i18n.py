"""i18n 集成测试(Slice 1.8)。

覆盖 i18n 改造的核心组件协作:
- term_translations.translate_term:术语翻译 + 严格抛错
- language.resolve_language:HTTP header 解析 + 规范化 + fallback
- prompts.render_prompt:按 language 加载模板 + 严格 fallback 抛错
- cache.InterpretationCache + CacheKey:language 维度隔离 + 老表自动 drop
- 端到端:resolve_language → render_prompt 链路

不覆盖:
- /api/interpret 路由完整测试(依赖 jwt + DB,留给现有 test_interpret_*.py)
- LLM 调用(留给 acceptance criteria 手动验收)
"""

from __future__ import annotations

import json
import re
import sqlite3
import tempfile
import os
from pathlib import Path

import pytest
from fastapi import Request

from app.ai.cache import InterpretationCache, _EXPECTED_COLUMNS
from app.ai.cache_key import CacheKey
from app.ai.prompts import (
    BAZI_DEEP_SPECIAL_PATTERN_SUFFIX,
    PROMPT_VERSIONS,
    _load_template,
    render_prompt,
)
from app.api.language import (
    DEFAULT_LANGUAGE,
    _extract_first_tag,
    _match_language,
    resolve_language,
)
from app.engine.term_translations import (
    STRENGTH_LABEL_EN,
    TERM_TRANSLATIONS,
    is_language_supported,
    translate_context,
    translate_term,
)


# ---------- term_translations ----------

class TestTranslateTerm:
    def test_chinese_identity(self):
        """中文目标语言直接返回原文(identity map)。"""
        assert translate_term("甲", "zh") == "甲"
        assert translate_term("比肩", "zh") == "比肩"
        assert translate_term("strong", "zh") == "strong"

    def test_heavenly_stems_en(self):
        """天干 10 个拼音翻译。"""
        assert translate_term("甲", "en") == "Jia"
        assert translate_term("乙", "en") == "Yi"
        assert translate_term("丙", "en") == "Bing"
        assert translate_term("丁", "en") == "Ding"
        assert translate_term("戊", "en") == "Wu"
        assert translate_term("己", "en") == "Ji"
        assert translate_term("庚", "en") == "Geng"
        assert translate_term("辛", "en") == "Xin"
        assert translate_term("壬", "en") == "Ren"
        assert translate_term("癸", "en") == "Gui"

    def test_earthly_branches_en(self):
        """地支 12 个拼音翻译。"""
        assert translate_term("子", "en") == "Zi"
        assert translate_term("丑", "en") == "Chou"
        assert translate_term("亥", "en") == "Hai"

    def test_five_elements_en(self):
        """五行字面意译。"""
        assert translate_term("木", "en") == "Wood"
        assert translate_term("火", "en") == "Fire"
        assert translate_term("土", "en") == "Earth"
        assert translate_term("金", "en") == "Metal"
        assert translate_term("水", "en") == "Water"

    def test_ten_gods_en_joey_yap(self):
        """十神 Joey Yap 体系翻译(劫财例外:2026-09-29 拍板改 Wealth Rival)。"""
        assert translate_term("比肩", "en") == "Companion"
        assert translate_term("劫财", "en") == "Wealth Rival"
        assert translate_term("食神", "en") == "Eating God"
        assert translate_term("伤官", "en") == "Hurting Officer"
        assert translate_term("偏财", "en") == "Indirect Wealth"
        assert translate_term("正财", "en") == "Direct Wealth"
        assert translate_term("正官", "en") == "Direct Officer"
        assert translate_term("七杀", "en") == "Seven Killings"
        assert translate_term("偏官", "en") == "Seven Killings"  # 同义
        assert translate_term("正印", "en") == "Direct Resource"
        assert translate_term("偏印", "en") == "Indirect Resource"

    def test_strength_label_en(self):
        """旺衰 label 翻译(raw key 对齐 iOS 客户端实际发送值)。"""
        assert translate_term("strong", "en") == "Strong"
        assert translate_term("weak", "en") == "Weak"
        assert translate_term("balanced", "en") == "Balanced"
        assert translate_term("special_pattern", "en") == "Special Pattern"

    def test_unregistered_term_raises_keyerror(self):
        """未注册术语抛 KeyError(显式失败,不静默返回中文)。"""
        with pytest.raises(KeyError, match="未注册 en 翻译"):
            translate_term("不存在的术语", "en")

    def test_unregistered_language_raises_keyerror(self):
        """未注册语言抛 KeyError。"""
        with pytest.raises(KeyError, match="未注册的目标语言"):
            translate_term("甲", "ja")  # ja 是未来扩展,当前未实现

    def test_is_language_supported(self):
        assert is_language_supported("zh") is True
        assert is_language_supported("en") is True
        assert is_language_supported("zh-hant") is True
        assert is_language_supported("ja") is False
        assert is_language_supported("es") is False

    def test_en_table_completeness(self):
        """en 表至少 42 项(覆盖 Slice 1 每日运势最小集)。

        明细:天干 10 + 地支 12 + 五行 5 + 十神 11(含偏官/七杀同义) +
        旺衰 label 4(raw key:strong/weak/balanced/special_pattern)= 42 项。
        """
        assert len(TERM_TRANSLATIONS["en"]) >= 42, (
            f"en 表应至少 42 项,实际 {len(TERM_TRANSLATIONS['en'])} 项")


# ---------- term_translations:zh-Hant(S2,i18n-zh-hant-plan.md D1) ----------

class TestTranslateTermZhHant:
    """zh-hant 术语表测试(显式注册表,值与 iOS BaziTerms zhHant 列对齐)。"""

    def test_identity_ganzi(self):
        """干支/五行全同形(identity 也显式进表)。"""
        assert translate_term("甲", "zh-hant") == "甲"
        assert translate_term("亥", "zh-hant") == "亥"
        assert translate_term("木", "zh-hant") == "木"

    def test_heteromorphic_terms(self):
        """异形术语抽查(十神/长生/纳音/神煞/合盘枚举)。"""
        assert translate_term("劫财", "zh-hant") == "劫財"
        assert translate_term("七杀", "zh-hant") == "七殺"
        assert translate_term("长生", "zh-hant") == "長生"   # 非恒等!
        assert translate_term("炉中火", "zh-hant") == "爐中火"
        assert translate_term("天乙贵人", "zh-hant") == "天乙貴人"
        assert translate_term("相克", "zh-hant") == "相剋"
        assert translate_term("六冲", "zh-hant") == "六沖"

    def test_unregistered_term_raises_keyerror(self):
        with pytest.raises(KeyError, match="未注册 zh-hant 翻译"):
            translate_term("不存在的术语", "zh-hant")

    def test_zh_hant_key_parity_with_en(self):
        """zh-hant 表键集合 = en 表键集合 − raw strength key 集。

        raw key(strong/weak/...)是 Latin 控制键,不属 CJK 术语域,
        context 翻译不碰(S09 口径),因此有意不进 zh-hant 表。
        其余键集合两语言必须相等——加 en 术语忘加 zh-hant 时此处拦截。
        """
        en_keys = set(TERM_TRANSLATIONS["en"])
        hant_keys = set(TERM_TRANSLATIONS["zh-hant"])
        assert hant_keys == en_keys - set(STRENGTH_LABEL_EN), (
            f"仅 en: {sorted((en_keys - set(STRENGTH_LABEL_EN)) - hant_keys)}; "
            f"仅 zh-hant: {sorted(hant_keys - en_keys)}")

    def test_zh_hant_values_are_traditional(self):
        """zh-hant 译值不得残留简体专属字形(键是简体 id,值必须繁体)。"""
        # 简体专属字抽样集(传统字形分别为 傷財殺帶臨絕養沖無從後發長貴馬驛
        # 將蓋輿祿災羅紅艷優補業氣);同形字(一/七/天…)不在此列
        simplified_only = set("伤财杀带临绝养冲无从后发长贵马驿将盖舆禄灾罗红艳优补业气")
        for key, value in TERM_TRANSLATIONS["zh-hant"].items():
            bad = set(value) & simplified_only
            assert not bad, f"{key!r} 译值 {value!r} 含简体字形 {sorted(bad)}"


# ---------- 共享测试 helper ----------

def _make_mock_request(headers: dict[str, str]) -> Request:
    """构造 mock Request(只关心 headers)。

    模块级共享 helper,避免在每个测试类里重复定义。
    """
    class MockHeaders:
        def __init__(self, h):
            self._h = {k.lower(): v for k, v in h.items()}
        def get(self, k, default=None):
            return self._h.get(k.lower(), default)
    class MockRequest:
        def __init__(self, h):
            self.headers = MockHeaders(h)
    return MockRequest(headers)


# ---------- language.resolve_language ----------

class TestResolveLanguage:
    """语言解析层测试(i18n 决策 2:方案 4 双 header 混合)。"""

    _make_request = staticmethod(_make_mock_request)

    def test_accept_language_en_only(self):
        """v1 主路径:iOS 不发 X-QiCompass-Lang,只发 Accept-Language。"""
        r = self._make_request({"Accept-Language": "en-US,en;q=0.8"})
        assert resolve_language(r) == "en"

    def test_accept_language_zh_hans_cn(self):
        """中文 locale 规范化(zh-Hans-CN → zh)。"""
        r = self._make_request({"Accept-Language": "zh-Hans-CN,zh;q=0.9"})
        assert resolve_language(r) == "zh"

    def test_x_qicompass_lang_overrides_accept_language(self):
        """X-QiCompass-Lang 优先(v2 App 内切换场景)。"""
        r = self._make_request({
            "X-QiCompass-Lang": "en",
            "Accept-Language": "zh-CN",
        })
        assert resolve_language(r) == "en"

    def test_x_qicompass_lang_unregistered_falls_back(self):
        """X-QiCompass-Lang 未注册语言(ja)→ fallback 到 Accept-Language。"""
        r = self._make_request({
            "X-QiCompass-Lang": "ja",
            "Accept-Language": "en-US",
        })
        assert resolve_language(r) == "en"

    def test_no_headers_defaults_zh(self):
        """无任何 header → 默认 zh。"""
        r = self._make_request({})
        assert resolve_language(r) == DEFAULT_LANGUAGE
        assert DEFAULT_LANGUAGE == "zh"

    def test_accept_language_unregistered_defaults_zh(self):
        """Accept-Language 是未注册语言(ja)→ fallback zh(不静默用 en)。"""
        r = self._make_request({"Accept-Language": "ja-JP"})
        assert resolve_language(r) == "zh"

    def test_x_qicompass_lang_case_insensitive(self):
        """X-QiCompass-Lang 大小写不敏感。"""
        r = self._make_request({"X-QiCompass-Lang": "EN"})
        assert resolve_language(r) == "en"

    def test_complex_accept_language_header(self):
        """复杂 Accept-Language(zh-Hans-CN,zh;q=0.9,en;q=0.8)取 primary。"""
        r = self._make_request({"Accept-Language": "zh-Hans-CN,zh;q=0.9,en;q=0.8"})
        assert resolve_language(r) == "zh"


class TestResolveLanguageZhVariants:
    """D4(i18n-zh-hant-plan.md):zh 变体解析——繁体系统用户零操作拿繁体。"""

    _make_request = staticmethod(_make_mock_request)

    @pytest.mark.parametrize("accept", [
        "zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK", "zh-MO",
        "zh-Hant-HK,zh;q=0.9", "zh-TW,zh;q=0.9,en;q=0.8",
    ])
    def test_accept_language_zh_hant_variants(self, accept: str):
        """Accept-Language 携带繁体 script/region → zh-hant。"""
        r = self._make_request({"Accept-Language": accept})
        assert resolve_language(r) == "zh-hant"

    @pytest.mark.parametrize("accept", [
        "zh", "zh-CN", "zh-SG", "zh-Hans", "zh-Hans-CN",
        "zh-CN,zh;q=0.9,en;q=0.8", "zhXX",
    ])
    def test_accept_language_zh_hans_variants(self, accept: str):
        """裸 zh / Hans / CN / SG / 未知 region → zh(简体为默认侧,不猜繁体)。"""
        r = self._make_request({"Accept-Language": accept})
        assert resolve_language(r) == "zh"

    @pytest.mark.parametrize("override", ["zh-hant", "zh-Hant", "zh-TW"])
    def test_x_qicompass_lang_zh_hant(self, override: str):
        """X-QiCompass-Lang 同样过变体解析(D6 iOS 发规范化值,大小写/变体兜底)。"""
        r = self._make_request({
            "X-QiCompass-Lang": override,
            "Accept-Language": "zh-CN",
        })
        assert resolve_language(r) == "zh-hant"

    def test_x_qicompass_lang_zh_hant_overrides_hant_accept(self):
        """简体 override 覆盖繁体 Accept-Language(显式优先级)。"""
        r = self._make_request({
            "X-QiCompass-Lang": "zh",
            "Accept-Language": "zh-Hant-TW",
        })
        assert resolve_language(r) == "zh"

    def test_hant_accept_beats_registered_check(self):
        """zh-hant 在 TERM_TRANSLATIONS 已注册(is_language_supported 不再坍缩)。"""
        r = self._make_request({"Accept-Language": "zh-Hant"})
        assert resolve_language(r) == "zh-hant"


class TestMatchLanguage:
    def test_zh_script_and_region_matrix(self):
        assert _match_language("zh-Hant") == "zh-hant"
        assert _match_language("zh-hant-tw") == "zh-hant"
        assert _match_language("zh-TW") == "zh-hant"
        assert _match_language("zh-HK") == "zh-hant"
        assert _match_language("zh-MO") == "zh-hant"
        assert _match_language("zh-Hans") == "zh"
        assert _match_language("zh-CN") == "zh"
        assert _match_language("zh-SG") == "zh"
        assert _match_language("zh") == "zh"
        assert _match_language("ZH") == "zh"  # 大小写不敏感

    def test_en_and_unregistered(self):
        assert _match_language("en") == "en"
        assert _match_language("en-US") == "en"
        assert _match_language("ja-JP") is None
        assert _match_language("fr") is None
        assert _match_language("") is None
        assert _match_language("---") is None


class TestExtractFirstTag:
    def test_complex_header(self):
        assert _extract_first_tag("zh-Hans-CN,zh;q=0.9,en;q=0.8") == "zh-Hans-CN"

    def test_single_tag_with_region(self):
        assert _extract_first_tag("en-US") == "en-US"

    def test_single_tag_only(self):
        assert _extract_first_tag("en") == "en"

    def test_empty_string(self):
        assert _extract_first_tag("") is None

    def test_quality_param(self):
        """质量参数被剥离。"""
        assert _extract_first_tag("zh-Hant-TW;q=0.8") == "zh-Hant-TW"


# ---------- prompts.render_prompt ----------

class TestRenderPromptI18n:
    """render_prompt i18n 行为测试。"""

    @pytest.fixture
    def daily_fortune_context(self) -> dict:
        """最小合法 daily_fortune context(对齐 REQUIRED_FIELDS)。"""
        return {
            "day_master": "甲",
            "day_master_element": "木",
            "day_master_strength": "strong",
            "favorable_elements": "水",
            "unfavorable_elements": "金",
            "date": "2026-08-12",
            "lunar_date": "七月初十",
            "day_pillar": "甲子",
            "day_stem": "甲",
            "day_stem_element": "木",
            "day_branch": "子",
            "day_branch_element": "水",
            "day_relation": "比肩",
            "day_chong": "午",
            "hour_pillars_with_relations": "子时(23-01): 甲子 比肩",
            "huangli_yi": "祈福",
            "huangli_ji": "动土",
        }

    def test_default_language_is_zh(self, daily_fortune_context):
        """render_prompt 不传 language 默认 zh(向后兼容)。"""
        prompt = render_prompt("daily_fortune", daily_fortune_context)
        assert "你是一位精通流日推断的命理师" in prompt
        assert "甲" in prompt

    def test_explicit_zh(self, daily_fortune_context):
        """显式 language='zh' 加载中文模板。"""
        prompt = render_prompt("daily_fortune", daily_fortune_context, language="zh")
        assert "你是一位精通流日推断的命理师" in prompt

    def test_explicit_en(self, daily_fortune_context):
        """language='en' 加载英文模板(无 context 翻译,术语保留中文)。"""
        # 注:这是单元测试,只测 render_prompt,不调用 translate_context
        # 完整翻译链路测试见 TestEndToEndI18nFullFlow
        prompt = render_prompt("daily_fortune", daily_fortune_context, language="en")
        assert "You are a master of Chinese BaZi" in prompt
        # 占位符替换正常(context 未翻译,"甲" 是中文原值)
        assert "Day Master 甲" in prompt
        assert "Day Pillar: 甲子" in prompt

    def test_zh_and_en_different(self, daily_fortune_context):
        """中英模板内容不同(确认是真不同文件)。"""
        zh_prompt = render_prompt("daily_fortune", daily_fortune_context, language="zh")
        en_prompt = render_prompt("daily_fortune", daily_fortune_context, language="en")
        assert zh_prompt != en_prompt

    def test_en_missing_for_other_modules_raises(self):
        """其他 module(bazi_deep)无英文模板 → 显式抛 FileNotFoundError。"""
        with pytest.raises(FileNotFoundError, match="bazi_deep"):
            _load_template("bazi_deep", "en", 2)

    def test_zh_fallback_to_legacy_templates(self):
        """zh 模板文件缺失时 fallback 到 _LEGACY_TEMPLATES(Slice 1 过渡)。"""
        # bazi_deep 还没文件化,zh 应 fallback 到硬编码
        template = _load_template("bazi_deep", "zh", 2)
        assert "你是一位精通中国传统四柱八字命理的大师" in template

    def test_lru_cache_works(self, daily_fortune_context):
        """lru_cache 缓存生效(同 key 返回同对象)。"""
        t1 = _load_template("daily_fortune", "en", 2)
        t2 = _load_template("daily_fortune", "en", 2)
        # lru_cache 应返回同一对象(基于 id)
        assert id(t1) == id(t2)

    def test_unknown_hour_degraded_variant_en_full_flow(self,
                                                        daily_fortune_context):
        """S09:unknown_hour context 的 en 渲染走降级变体文件;
        translate_context 先行(strength raw key unknown_hour 已注册,
        未注册会 KeyError → 500),变体无 12 时辰段/喜忌栏。"""
        ctx = {k: v for k, v in daily_fortune_context.items()
               if k not in ("favorable_elements", "unfavorable_elements",
                            "hour_pillars_with_relations")}
        ctx["day_master_strength"] = "unknown_hour"
        # 真实链路:translate_context → render_prompt(变体)。
        # strength raw key 不被翻译(控制信号翻译不变式),变体切换仍命中
        translated = translate_context(ctx, "en", "daily_fortune")
        assert translated["day_master_strength"] == "unknown_hour"
        prompt = render_prompt("daily_fortune", translated, language="en")
        assert "Day Pillar only" in prompt          # 诚实局限句(变体标志)
        assert "birth hour" in prompt.lower()
        assert "12 Hour Pillars" not in prompt       # 12 时辰段整体删除
        assert "Favorable Elements:" not in prompt   # 喜忌栏整体删除
        # v4(S6):输出契约是 JSON 五段,模板 {{ }} 还原后含字面 { }——
        # 断言占位符形态不残留,而非全 prompt 无 "{"
        assert not re.search(r"\{[a-z_]+\}", prompt)
        assert '"headline"' in prompt


# ---------- cache + CacheKey language 维度 ----------

class TestCacheLanguageIsolation:
    """SQLite 缓存 language 维度隔离测试(i18n 决策 3)。"""

    @pytest.fixture
    def cache(self, tmp_path):
        """每个测试用独立 SQLite 文件。"""
        db_path = str(tmp_path / "test_cache.db")
        c = InterpretationCache(db_path)
        c.init_schema()
        return c

    def test_same_content_hash_different_language_isolated(self, cache):
        """同 content_hash + 不同 language = 独立缓存条目。"""
        key_zh = CacheKey(
            content_hash="hash1", module="daily_fortune", prompt_version=2,
            target_date="2026-08-12", prompt_hash="ph1",
            provider="anthropic", model="claude-sonnet-4-6", language="zh",
        )
        key_en = CacheKey(
            content_hash="hash1", module="daily_fortune", prompt_version=2,
            target_date="2026-08-12", prompt_hash="ph1",
            provider="anthropic", model="claude-sonnet-4-6", language="en",
        )
        cache.set(key_zh, "今日运势中文版", "2026-08-12T00:00:00+00:00")
        cache.set(key_en, "Today fortune English", "2026-08-12T00:00:00+00:00")

        assert cache.get(key_zh)["interpretation"] == "今日运势中文版"
        assert cache.get(key_en)["interpretation"] == "Today fortune English"

    def test_cachekey_default_language_zh(self):
        """CacheKey 不传 language 默认 zh(向后兼容老调用)。"""
        key = CacheKey(
            content_hash="h", module="daily_fortune", prompt_version=2,
            target_date=None, prompt_hash="ph",
            provider="anthropic", model="claude-sonnet-4-6",
        )
        assert key.language == "zh"

    def test_legacy_table_auto_dropped(self, tmp_path):
        """老表(缺 language 列)被 init_schema 识别并 drop 重建。"""
        db_path = str(tmp_path / "legacy.db")
        # 手动建一个老 schema 的表(7 维 PK,无 language)
        conn = sqlite3.connect(db_path)
        conn.execute("""CREATE TABLE interpretation_cache (
            content_hash TEXT, module TEXT, prompt_version INTEGER,
            target_date TEXT, prompt_hash TEXT, provider TEXT, model TEXT,
            interpretation TEXT, generated_at TEXT,
            PRIMARY KEY (content_hash, module, prompt_version, target_date,
                         prompt_hash, provider, model)
        )""")
        conn.commit()
        conn.close()

        # init_schema 应识别为 legacy 并重建
        cache = InterpretationCache(db_path)
        cache.init_schema()

        # 重建后列应包含 language
        conn = sqlite3.connect(db_path)
        cols = {row[1] for row in conn.execute(
            "PRAGMA table_info(interpretation_cache)").fetchall()}
        conn.close()
        assert cols == _EXPECTED_COLUMNS
        assert "language" in cols

    def test_expected_columns_includes_language(self):
        """_EXPECTED_COLUMNS 包含 language(否则会误 drop 新表)。"""
        assert "language" in _EXPECTED_COLUMNS


# ---------- 端到端:resolve_language → render_prompt 链路 ----------

class TestEndToEndI18nFlow:
    """模拟路由层 wiring 链路(不依赖 FastAPI/jwt/DB)。"""

    @pytest.fixture
    def daily_fortune_context(self) -> dict:
        return {
            "day_master": "甲", "day_master_element": "木",
            "day_master_strength": "strong",
            "favorable_elements": "水", "unfavorable_elements": "金",
            "date": "2026-08-12", "lunar_date": "七月初十",
            "day_pillar": "甲子", "day_stem": "甲", "day_stem_element": "木",
            "day_branch": "子", "day_branch_element": "水",
            "day_relation": "比肩", "day_chong": "午",
            "hour_pillars_with_relations": "子时: 甲子 比肩",
            "huangli_yi": "祈福", "huangli_ji": "动土",
        }

    @staticmethod
    def _make_request(headers: dict[str, str]) -> Request:
        return _make_mock_request(headers)

    def test_zh_request_zh_prompt(self, daily_fortune_context):
        """中文 request → 中文 prompt(向后兼容)。"""
        request = self._make_request({"Accept-Language": "zh-Hans-CN"})
        language = resolve_language(request)
        assert language == "zh"

        prompt = render_prompt("daily_fortune", daily_fortune_context, language=language)
        assert "你是一位精通流日推断的命理师" in prompt

    def test_en_request_en_prompt(self, daily_fortune_context):
        """英文 request → 英文 prompt(v1 主路径)。"""
        request = self._make_request({"Accept-Language": "en-US,en;q=0.8"})
        language = resolve_language(request)
        assert language == "en"

        prompt = render_prompt("daily_fortune", daily_fortune_context, language=language)
        assert "You are a master of Chinese BaZi" in prompt

    def test_no_header_defaults_zh_prompt(self, daily_fortune_context):
        """无 header → zh → 中文 prompt(默认行为)。"""
        request = self._make_request({})
        language = resolve_language(request)
        assert language == "zh"

        prompt = render_prompt("daily_fortune", daily_fortune_context, language=language)
        assert "你是一位精通流日推断的命理师" in prompt


# ---------- context 数据翻译层(i18n 决策 1:方案 3b) ----------

class TestTranslateContext:
    """context 数据翻译测试(Slice 1.7.5)。"""

    @pytest.fixture
    def daily_fortune_context(self) -> dict:
        return {
            "day_master": "甲", "day_master_element": "木",
            "day_master_strength": "strong",
            "favorable_elements": "木火", "unfavorable_elements": "金水",
            "date": "2026-08-12", "lunar_date": "七月初十",
            "day_pillar": "甲子", "day_stem": "甲", "day_stem_element": "木",
            "day_branch": "子", "day_branch_element": "水",
            "day_relation": "比肩", "day_chong": "午",
            "hour_pillars_with_relations": "子时(23-01): 甲子 比肩",
            "huangli_yi": "祈福", "huangli_ji": "动土",
        }

    def test_zh_identity(self, daily_fortune_context):
        """zh 目标语言 → identity(直接返回原 context)。"""
        result = translate_context(daily_fortune_context, "zh", "daily_fortune")
        assert result == daily_fortune_context

    def test_en_single_term_fields(self, daily_fortune_context):
        """en 翻译单术语字段。day_master_strength 不译(S09:raw key 是渲染层
        分支控制信号,翻译会破坏 unknown_hour/special_pattern 降级判定)。"""
        result = translate_context(daily_fortune_context, "en", "daily_fortune")
        assert result["day_master"] == "Jia"
        assert result["day_master_element"] == "Wood"
        assert result["day_master_strength"] == "strong"  # raw key 原样保留
        assert result["day_stem"] == "Jia"
        assert result["day_branch"] == "Zi"
        assert result["day_stem_element"] == "Wood"
        assert result["day_branch_element"] == "Water"
        assert result["day_relation"] == "Companion"
        assert result["day_chong"] == "Wu"

    def test_en_composite_pillar_field(self, daily_fortune_context):
        """en 翻译复合干支字段(甲子 → Jia Zi)。"""
        result = translate_context(daily_fortune_context, "en", "daily_fortune")
        assert result["day_pillar"] == "Jia Zi"

    def test_en_element_list_fields(self, daily_fortune_context):
        """en 翻译五行列表字段(木火 → Wood Fire)。"""
        result = translate_context(daily_fortune_context, "en", "daily_fortune")
        assert result["favorable_elements"] == "Wood Fire"
        assert result["unfavorable_elements"] == "Metal Water"

    def test_en_element_list_wire_format_with_separator(self):
        """en 翻译真实 wire 格式喜忌列表(iOS 用 ", " join,非连写)。

        回归锚点:旧实现对 "木, 水" 整体判 _TRANSLATION_FAILED → en prompt
        静默留中文;夹具必须覆盖带分隔符格式(PromptContextBuilder.swift:79
        `favorableElements.joined(separator: ", ")`)。
        """
        ctx = {"favorable_elements": "木, 水", "unfavorable_elements": "土、金"}
        result = translate_context(ctx, "en", "daily_fortune")
        assert result["favorable_elements"] == "Wood, Water"
        assert result["unfavorable_elements"] == "Earth, Metal"

    def test_en_preserves_non_translatable_fields(self, daily_fortune_context):
        """en 不翻译字段保留原文(date / lunar_date / hour_pillars / huangli)。"""
        result = translate_context(daily_fortune_context, "en", "daily_fortune")
        assert result["date"] == "2026-08-12"
        assert result["lunar_date"] == "七月初十"
        assert result["hour_pillars_with_relations"] == "子时(23-01): 甲子 比肩"
        assert result["huangli_yi"] == "祈福"
        assert result["huangli_ji"] == "动土"

    def test_en_does_not_mutate_original(self, daily_fortune_context):
        """en 翻译不修改原 context(返回新 dict)。"""
        original_day_master = daily_fortune_context["day_master"]
        translate_context(daily_fortune_context, "en", "daily_fortune")
        assert daily_fortune_context["day_master"] == original_day_master

    def test_unimplemented_module_returns_original(self):
        """未实现翻译规则的 module(bazi_deep)→ 返回原 context(Slice 2/3/4 跟进)。"""
        ctx = {"day_master": "甲"}
        result = translate_context(ctx, "en", "bazi_deep")
        assert result == ctx  # 原样返回

    def test_non_string_fields_preserved(self):
        """非字符串字段保留(防御)。"""
        ctx = {"day_master": 123, "day_pillar": None, "other": ["a", "b"]}
        result = translate_context(ctx, "en", "daily_fortune")
        assert result["day_master"] == 123
        assert result["day_pillar"] is None
        assert result["other"] == ["a", "b"]

    def test_pillar_non_standard_length_preserved(self):
        """非标准长度 day_pillar 保留原文(避免误伤)。"""
        ctx = {"day_pillar": "甲子寅"}  # 长度 3,非标准
        result = translate_context(ctx, "en", "daily_fortune")
        assert result["day_pillar"] == "甲子寅"

    def test_element_list_with_unknown_char_preserved(self):
        """五行列表含未知字符 → 保留原文(避免误伤)。"""
        ctx = {"favorable_elements": "木火未知"}
        result = translate_context(ctx, "en", "daily_fortune")
        assert result["favorable_elements"] == "木火未知"  # "未知" 不在表里


class TestEndToEndI18nFullFlow:
    """端到端:resolve_language → translate_context → render_prompt 完整链路。"""

    @pytest.fixture
    def daily_fortune_context(self) -> dict:
        return {
            "day_master": "甲", "day_master_element": "木",
            "day_master_strength": "strong",
            "favorable_elements": "木火", "unfavorable_elements": "金水",
            "date": "2026-08-12", "lunar_date": "七月初十",
            "day_pillar": "甲子", "day_stem": "甲", "day_stem_element": "木",
            "day_branch": "子", "day_branch_element": "水",
            "day_relation": "比肩", "day_chong": "午",
            "hour_pillars_with_relations": "子时: 甲子 比肩",
            "huangli_yi": "祈福", "huangli_ji": "动土",
        }

    @staticmethod
    def _make_request(headers: dict[str, str]) -> Request:
        return _make_mock_request(headers)

    def test_en_full_flow_produces_english_prompt(self, daily_fortune_context):
        """英文请求 → 全英文 prompt(术语已翻译,无中文残留于关键 term 字段)。"""
        request = self._make_request({"Accept-Language": "en-US,en;q=0.8"})
        language = resolve_language(request)
        assert language == "en"

        translated_ctx = translate_context(daily_fortune_context, language, "daily_fortune")
        prompt = render_prompt("daily_fortune", translated_ctx, language=language)

        # 关键术语已翻译
        assert "Day Master Jia" in prompt
        assert "Day Pillar: Jia Zi" in prompt
        assert "Companion" in prompt  # day_relation
        # day_master_strength 保留 raw key(S09:渲染层控制信号,不翻译,与 zh 一致)
        assert "Day Master Jia (Wood), strong" in prompt
        assert "Wood Fire" in prompt  # favorable_elements
        assert "Metal Water" in prompt  # unfavorable_elements

    def test_zh_full_flow_preserves_chinese(self, daily_fortune_context):
        """中文请求 → 全中文 prompt(向后兼容)。"""
        request = self._make_request({"Accept-Language": "zh-Hans-CN"})
        language = resolve_language(request)
        assert language == "zh"

        translated_ctx = translate_context(daily_fortune_context, language, "daily_fortune")
        prompt = render_prompt("daily_fortune", translated_ctx, language=language)

        assert "你是一位精通流日推断的命理师" in prompt
        assert "日主 甲" in prompt  # 中文模板 + 中文 context
        assert "比肩" in prompt


# ---------- T1c(i18n-trilingual,2026-09-22):deep(M0-M7)/compat 的 en 翻译与渲染 ----------

# 渲染后不得残留未填充占位符(单花括号 {name};模板 JSON 块的 {{}} 已折叠为字面 {})
_UNFILLED_PLACEHOLDER = re.compile(r"\{[a-z_][a-z0-9_]*\}")


class TestDeepEnTranslation:
    """deep(M0-M7)context:仅译 chart(engine 术语 JSON),其余字段不动。"""

    @staticmethod
    def _chart_json() -> str:
        return json.dumps({
            "meta": {"locale": "zh-CN", "gender": "female",
                     "solar_term_boundary": "惊蛰后"},
            "pillars": {"year": {
                "gan_zhi": "庚午", "gan": "庚", "zhi": "午",
                "gan_element": "metal", "zhi_element": "fire",
                "hide_gan": ["丁", "己"],
                "shishen_gan": "七杀", "shishen_zhi": ["正官", "正财"],
                "nayin": "路旁土", "dishi": "死", "xunkong": "戌亥"}},
            "day_master": {"stem": "甲", "element": "木",
                           "strength_score": None, "strength_label": "偏弱"},
            "ten_god_weights": {"七杀": 5, "正财": 3},
        }, ensure_ascii=False)

    def test_chart_values_translated_meta_kept(self):
        ctx = {"chart": self._chart_json()}
        out = translate_context(ctx, "en", "m0_structure")
        chart = json.loads(out["chart"])
        pillar = chart["pillars"]["year"]
        assert pillar["gan_zhi"] == "Geng Wu"           # 干支对
        assert pillar["gan"] == "Geng"                  # 单天干
        assert pillar["shishen_gan"] == "Seven Killings"
        assert pillar["shishen_zhi"] == ["Direct Officer", "Direct Wealth"]
        assert pillar["hide_gan"] == ["Ding", "Ji"]
        assert pillar["nayin"] == "Roadside Earth"
        assert pillar["dishi"] == "Death"
        assert pillar["xunkong"] == "Xu Hai"
        assert pillar["gan_element"] == "metal"         # 已拉丁,静默原样
        assert chart["day_master"]["element"] == "Wood"
        assert chart["day_master"]["strength_label"] == "Slightly Weak"
        assert chart["ten_god_weights"] == {"Seven Killings": 5,
                                            "Direct Wealth": 3}
        # meta 整体保留(日期/locale/节气界非术语域)
        assert chart["meta"]["solar_term_boundary"] == "惊蛰后"
        # 原 context 不被修改(shallow copy 语义)
        assert json.loads(ctx["chart"])["pillars"]["year"]["shishen_gan"] == "七杀"

    def test_chain_and_user_fields_untouched(self):
        ctx = {"chart": self._chart_json(),
               "structure_fingerprint": "以正财为轴的结构",
               "age": 30, "current_concern": "睡眠"}
        out = translate_context(ctx, "en", "m4_health")
        assert out["structure_fingerprint"] == "以正财为轴的结构"  # LLM 产出不动
        assert out["age"] == 30
        assert out["current_concern"] == "睡眠"  # 用户输入不动

    def test_render_m0_en_full_chain(self):
        """en M0 全链路:translate_context → render,不再 FileNotFoundError。"""
        ctx = translate_context({"chart": self._chart_json()},
                                "en", "m0_structure")
        prompt = render_prompt("m0_structure", ctx, language="en")
        assert "chart-structure analyst" in prompt
        assert "Seven Killings" in prompt
        assert "Geng Wu" in prompt
        assert not _UNFILLED_PLACEHOLDER.search(prompt)

    def test_render_m7_en_chain_fields(self):
        """M7 无 chart,链式注入字段(英文产出)原样渲染。"""
        ctx = {"one_leverage": "expression under pressure",
               "switch_actions": "ship weekly",
               "environment_checklist": "yes/no questions",
               "leverage": "output stage"}
        prompt = render_prompt("m7_manual", ctx, language="en")
        assert "expression under pressure" in prompt
        assert not _UNFILLED_PLACEHOLDER.search(prompt)

    @pytest.mark.parametrize("label,en", [
        ("时辰未知", "Hour Unknown"),    # iOS unknown_hour(S06 时辰未知盘走 deep)
        ("未判定", "Undetermined"),      # iOS 老 response nil 兜底
        ("从格特征", "Special Pattern"),
    ])
    def test_strength_label_ios_values_translated(self, label: str, en: str):
        """iOS buildV1ChartJSON 的 strength_label 全值域翻译(review 补)。

        backend chart_builder 只产 4 个 label;iOS 侧多两个(时辰未知/未判定),
        时辰未知盘可走 deep S06 降级叙事 → 这两个值必须注册,否则 en prompt
        静默留中文(带 warn)。
        """
        chart = json.dumps(
            {"day_master": {"stem": "甲", "element": "木",
                            "strength_score": None, "strength_label": label}},
            ensure_ascii=False)
        out = translate_context({"chart": chart}, "en", "m0_structure")
        assert json.loads(out["chart"])["day_master"]["strength_label"] == en


class TestCompatEnTranslation:
    """compat(free/paid)context:分组翻译(daily 同款策略)。"""

    @staticmethod
    def _context() -> dict:
        return {
            "context_label": "通用",
            "gender_a": "男", "city_a": "北京", "birth_a": "1990-03-05 07:20",
            "day_master_a": "甲", "day_master_strength_a": "weak",
            "favorable_a": "木火",
            "year_a": "庚午", "month_a": "己卯", "day_a": "甲子", "hour_a": "丁卯",
            "element_balance_a": "木3火2土1金1水1",
            "gender_b": "女", "city_b": "上海", "birth_b": "1992-08-10 14:00",
            "day_master_b": "丙", "day_master_strength_b": "strong",
            "favorable_b": "土金",
            "year_b": "壬申", "month_b": "戊申", "day_b": "丙午", "hour_b": "乙未",
            "element_balance_b": "木1火3土2金2水2",
            "five_elements_assessment": "互补佳",
            "day_master_relation": "相生",
            "zodiac_match": "六合",
            "branch_harmony": "无冲无刑",
            "synced_fortune_table": "- 2026:A「乙亥运 丙午年」B「丁丑运 丙午年」→ 同步走强",
        }

    def test_field_groups_translated(self):
        out = translate_context(self._context(), "en", "compatibility_free")
        assert out["day_master_a"] == "Jia"                    # 单术语(严格)
        assert out["five_elements_assessment"] == "Strongly complementary"
        assert out["day_master_relation"] == "Generating cycle"
        assert out["zodiac_match"] == "Six Harmony"
        assert out["branch_harmony"] == "No clash, no punishment"
        assert out["year_a"] == "Geng Wu"                      # 干支柱(复合)
        assert out["day_a"] == "Jia Zi"
        assert out["favorable_a"] == "Wood Fire"                # 喜忌列表(连写)
        assert out["element_balance_a"] == "Wood 3 Fire 2 Earth 1 Metal 1 Water 1"
        assert out["gender_a"] == "Male"                        # 宽容单值(已注册)
        assert out["context_label"] == "general"
        # 不翻译字段(口径留痕见 _translate_compat_context)
        assert out["day_master_strength_a"] == "weak"           # raw key
        assert out["city_a"] == "北京"                           # 用户/locale 数据
        assert "同步走强" in out["synced_fortune_table"]         # Slice 1 黄历先例

    def test_favorable_wire_format_with_separator(self):
        """喜忌真实 wire 格式(iOS ", " join,+Compatibility.swift:99)也翻译。

        回归锚点:旧 _translate_element_list 只认纯 CJK 连写,对 "木, 火"
        判失败静默留中文。
        """
        ctx = self._context()
        ctx["favorable_a"] = "木, 火"
        ctx["favorable_b"] = "土金"  # 连写格式共存(防御两种来源)
        out = translate_context(ctx, "en", "compatibility_free")
        assert out["favorable_a"] == "Wood, Fire"
        assert out["favorable_b"] == "Earth Metal"

    def test_unknown_enum_raises_keyerror(self):
        """合盘枚举未注册 → 显式 KeyError(两端加值忘同步表时的守门)。"""
        ctx = self._context()
        ctx["zodiac_match"] = "暗合"  # 假设后端加了新枚举但表未同步
        with pytest.raises(KeyError, match="暗合"):
            translate_context(ctx, "en", "compatibility_free")

    def test_nonstandard_pillar_tolerant(self):
        """时辰未知占位等非标准干支 → warn + 保留(daily 复合字段同款容忍)。"""
        ctx = self._context()
        ctx["hour_a"] = "时辰未知"
        out = translate_context(ctx, "en", "compatibility_free")
        assert out["hour_a"] == "时辰未知"

    def test_render_free_and_paid_en_full_chain(self):
        """en 合盘全链路渲染(不再 FileNotFoundError)。"""
        for module in ("compatibility_free", "compatibility_paid"):
            ctx = translate_context(self._context(), "en", module)
            prompt = render_prompt(module, ctx, language="en")
            assert "Geng Wu" in prompt
            assert "Six Harmony" in prompt
            assert "general dimension" in prompt  # context_label 已译
            assert not _UNFILLED_PLACEHOLDER.search(prompt)


class TestSpecialPatternSuffixFiles:
    """T1c:suffix 文件化(zh byte-identical + en 新译,替换原非 zh raise)。"""

    @pytest.mark.parametrize("version", [3, 6])
    def test_zh_suffix_files_byte_identical(self, version: int):
        assert _load_template(
            "_special_pattern_suffix", "zh", version
        ) == BAZI_DEEP_SPECIAL_PATTERN_SUFFIX

    @pytest.mark.parametrize("version", [3, 6])
    def test_en_suffix_files_exist(self, version: int):
        suffix = _load_template("_special_pattern_suffix", "en", version)
        assert "special-pattern" in suffix
        assert "must not give any definitive" in suffix


# ---------- S2(i18n-zh-hant-plan.md):zh-Hant context 翻译 + 渲染 + 模板 parity ----------

class TestZhHantTranslateContext:
    """zh-hant context 翻译:术语转繁、干支/列表连写无空格(joiner 语义)。"""

    @pytest.fixture
    def daily_fortune_context(self) -> dict:
        return {
            "day_master": "甲", "day_master_element": "木",
            "day_master_strength": "strong",
            "favorable_elements": "木火", "unfavorable_elements": "金水",
            "date": "2026-08-12", "lunar_date": "七月初十",
            "day_pillar": "庚午", "day_stem": "庚", "day_stem_element": "金",
            "day_branch": "午", "day_branch_element": "火",
            "day_relation": "七杀", "day_chong": "子",
            "hour_pillars_with_relations": "子时: 甲子 比肩",
            "huangli_yi": "祈福", "huangli_ji": "动土",
        }

    def test_daily_terms_traditional_no_space_join(self, daily_fortune_context):
        """单术语转繁;干支柱/喜忌列表连写(**不得**像 en 那样插空格)。"""
        out = translate_context(daily_fortune_context, "zh-hant", "daily_fortune")
        assert out["day_relation"] == "七殺"
        assert out["day_pillar"] == "庚午"
        assert out["favorable_elements"] == "木火"
        assert out["day_master"] == "甲"          # identity 也走表
        assert out["day_master_strength"] == "strong"  # raw key 不译(S09 口径)
        assert out["lunar_date"] == "七月初十"     # 不翻译字段保留

    def test_deep_chart_joiner_and_terms(self):
        """chart JSON:干支/地支对连写,十神/旺衰标签转繁,meta 保留。"""
        chart = json.dumps({
            "meta": {"locale": "zh-CN", "solar_term_boundary": "惊蛰后"},
            "pillars": {"year": {
                "gan_zhi": "庚午", "shishen_gan": "七杀",
                "nayin": "路旁土", "dishi": "长生", "xunkong": "戌亥"}},
            "day_master": {"strength_label": "从格特征"},
            "ten_god_weights": {"七杀": 5},
        }, ensure_ascii=False)
        out = translate_context({"chart": chart}, "zh-hant", "m0_structure")
        c = json.loads(out["chart"])
        assert c["pillars"]["year"]["gan_zhi"] == "庚午"      # 连写,非 "庚 午"
        assert c["pillars"]["year"]["dishi"] == "長生"
        assert c["pillars"]["year"]["xunkong"] == "戌亥"      # 连写
        assert c["pillars"]["year"]["shishen_gan"] == "七殺"
        assert c["day_master"]["strength_label"] == "從格特徵"
        assert c["ten_god_weights"] == {"七殺": 5}             # 键也译
        assert c["meta"]["solar_term_boundary"] == "惊蛰后"    # meta 整体保留

    def test_compat_enums_and_pillars(self):
        ctx = {
            "context_label": "通用", "gender_a": "男", "city_a": "北京",
            "birth_a": "1990-03-05 07:20", "day_master_a": "甲",
            "day_master_strength_a": "weak", "favorable_a": "木火",
            "year_a": "庚午", "month_a": "己卯", "day_a": "甲子", "hour_a": "丁卯",
            "element_balance_a": "木3火2土1金1水1",
            "gender_b": "女", "city_b": "上海", "birth_b": "1992-08-10 14:00",
            "day_master_b": "丙", "day_master_strength_b": "strong",
            "favorable_b": "土金",
            "year_b": "壬申", "month_b": "戊申", "day_b": "丙午", "hour_b": "乙未",
            "element_balance_b": "木1火3土2金2水2",
            "five_elements_assessment": "互补佳", "day_master_relation": "相克",
            "zodiac_match": "六冲", "branch_harmony": "无冲无刑",
            "synced_fortune_table": "- 2026:同步走强",
        }
        out = translate_context(ctx, "zh-hant", "compatibility_free")
        assert out["five_elements_assessment"] == "互補佳"
        assert out["day_master_relation"] == "相剋"
        assert out["zodiac_match"] == "六沖"
        assert out["branch_harmony"] == "無沖無刑"
        assert out["context_label"] == "通用"
        assert out["year_a"] == "庚午"                    # 连写
        assert out["day_master_strength_a"] == "weak"     # raw key
        assert out["city_a"] == "北京"                     # 用户数据不动


class TestZhHantRenderPrompt:
    """zh-hant 模板渲染(D5:转繁 + 模板内显式「全文用繁體中文書寫」指令)。"""

    @pytest.fixture
    def daily_fortune_context(self) -> dict:
        return {
            "day_master": "甲", "day_master_element": "木",
            "day_master_strength": "strong",
            "favorable_elements": "木火", "unfavorable_elements": "金水",
            "date": "2026-08-12", "lunar_date": "七月初十",
            "day_pillar": "庚午", "day_stem": "庚", "day_stem_element": "金",
            "day_branch": "午", "day_branch_element": "火",
            "day_relation": "七杀", "day_chong": "子",
            "hour_pillars_with_relations": "子时: 甲子 比肩",
            "huangli_yi": "祈福", "huangli_ji": "动土",
        }

    def test_daily_v4_zh_hant(self, daily_fortune_context):
        prompt = render_prompt(
            "daily_fortune", daily_fortune_context, language="zh-hant")
        assert "繁體中文" in prompt
        assert "流日沖：子" in prompt
        assert "庚午" in prompt           # context 已繁化的干支
        assert "黃曆宜" in prompt
        assert not re.search(r"\{[a-z_]+\}", prompt)  # 无未填充占位符

    def test_daily_unknown_hour_variant_zh_hant(self, daily_fortune_context):
        ctx = {k: v for k, v in daily_fortune_context.items()
               if k not in ("favorable_elements", "unfavorable_elements",
                            "hour_pillars_with_relations")}
        ctx["day_master_strength"] = "unknown_hour"
        translated = translate_context(ctx, "zh-hant", "daily_fortune")
        assert translated["day_master_strength"] == "unknown_hour"
        prompt = render_prompt("daily_fortune", translated, language="zh-hant")
        assert "時辰未知" in prompt
        assert "12 時辰" not in prompt        # 降级变体无 12 时辰段
        assert "命局喜" not in prompt          # 喜忌栏整体删除

    def test_m0_zh_hant(self):
        chart = json.dumps(
            {"pillars": {"year": {"gan_zhi": "庚午", "shishen_gan": "七殺"}},
             "day_master": {"strength_label": "偏弱"}},
            ensure_ascii=False)
        prompt = render_prompt(
            "m0_structure", {"chart": chart}, language="zh-hant")
        assert "模組 M0:識別主線結構" in prompt
        assert "繁體中文" in prompt
        assert "結構分析師" in prompt

    def test_compat_free_paid_zh_hant(self):
        ctx = {
            "context_label": "通用", "gender_a": "男", "city_a": "北京",
            "birth_a": "1990-03-05 07:20", "day_master_a": "甲",
            "day_master_strength_a": "weak", "favorable_a": "木火",
            "year_a": "庚午", "month_a": "己卯", "day_a": "甲子", "hour_a": "丁卯",
            "element_balance_a": "木3火2土1金1水1",
            "gender_b": "女", "city_b": "上海", "birth_b": "1992-08-10 14:00",
            "day_master_b": "丙", "day_master_strength_b": "strong",
            "favorable_b": "土金",
            "year_b": "壬申", "month_b": "戊申", "day_b": "丙午", "hour_b": "乙未",
            "element_balance_b": "木1火3土2金2水2",
            "five_elements_assessment": "互補佳", "day_master_relation": "相剋",
            "zodiac_match": "六沖", "branch_harmony": "無沖無刑",
            "synced_fortune_table": "- 2026:同步走強",
        }
        for module in ("compatibility_free", "compatibility_paid"):
            prompt = render_prompt(module, ctx, language="zh-hant")
            assert "八字合婚/合盤的大師" in prompt
            assert "繁體中文書寫" in prompt
            assert "干支接地" in prompt
            assert not re.search(r"\{[a-z_]+\}", prompt)

    def test_zh_hant_differs_from_zh_and_en(self, daily_fortune_context):
        zh = render_prompt("daily_fortune", daily_fortune_context, language="zh")
        hant = render_prompt("daily_fortune", daily_fortune_context,
                             language="zh-hant")
        en = render_prompt("daily_fortune", daily_fortune_context, language="en")
        assert len({zh, hant, en}) == 3  # 三份模板真不同


class TestZhHantTemplateFileParity:
    """S2 守护栏:现役模块当前版本的 zh-hant / en 模板文件必须存在。

    防「bump PROMPT_VERSION 时只补 zh/en 忘补 zh-hant」——那会让 zh-hant
    用户在版本切换后直接 FileNotFoundError → 500。alias 4 个
    (_LEGACY_TEMPLATES)与 daily_fortune_image(prompt 由代码拼装)不在
    文件化范围。
    """

    def test_current_version_templates_exist_for_zh_hant_and_en(self):
        from pathlib import Path

        from app.ai.prompts import PROMPTS_DIR, _LEGACY_TEMPLATES
        file_modules = [
            m for m in PROMPT_VERSIONS
            if m not in _LEGACY_TEMPLATES and m != "daily_fortune_image"
        ]
        assert len(file_modules) >= 11  # m0-m7 + compat free/paid + daily
        for module in file_modules:
            version = PROMPT_VERSIONS[module]
            for lang in ("zh", "zh-hant", "en"):
                path = Path(PROMPTS_DIR) / lang / f"{module}_v{version}.md"
                assert path.exists(), (
                    f"{lang} 缺 {module} 当前版本模板 {path}"
                    f"(bump 版本须三语同步建文件)")
        # daily 降级变体 + 从格 suffix(bazi_deep 家族版本号 3/6)
        version = PROMPT_VERSIONS["daily_fortune"]
        for lang in ("zh", "zh-hant", "en"):
            assert (Path(PROMPTS_DIR) / lang
                    / f"daily_fortune_unknown_hour_v{version}.md").exists()
            for suffix_version in (3, 6):
                assert (Path(PROMPTS_DIR) / lang
                        / f"_special_pattern_suffix_v{suffix_version}.md"
                        ).exists()

    def test_zh_hant_templates_have_traditional_output_instruction(self):
        """D5:每个 zh-hant 模板必须显式写明繁体输出指令(防转繁漏指令)。"""
        from pathlib import Path

        from app.ai.prompts import PROMPTS_DIR, _LEGACY_TEMPLATES
        file_modules = [
            m for m in PROMPT_VERSIONS
            if m not in _LEGACY_TEMPLATES and m != "daily_fortune_image"
        ]
        for module in file_modules:
            version = PROMPT_VERSIONS[module]
            text = (Path(PROMPTS_DIR) / "zh-hant"
                    / f"{module}_v{version}.md").read_text(encoding="utf-8")
            assert "繁體中文" in text, (
                f"zh-hant/{module} 缺「繁體中文」输出指令(D5:模板须显式写明)")
