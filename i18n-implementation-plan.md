# QiCompass i18n 实施计划

**状态**:2026-08-12 grill-me 完成的战略 + 执行层共识
**目标**:v1 中文(简)+ 英文,架构按"可扩展多语言"设计,内容翻译只投入做英文
**适用范围**:v1 阶段。v2 加语种靠 App Store Connect 国家数据决策,候选:西 + 日

---

## 1. 战略层共识

### 1.1 范围

| 维度 | v1 决策 |
|---|---|
| UI 语言 | 中文(简)+ 英文 |
| LLM prompt 语言 | 中文 + 英文(投入调优) |
| 后端架构 | 按"可扩展多语言"设计(双 header 解析 / 翻译表 / 模板分支) |
| 字体 | 系统 fallback 自处理(Songti SC + PingFang SC + SF Pro) |
| 第二波决策点 | v1 上线 60-90 天后看 App Store Connect 国家分布数据 |
| 第二波候选 | 西班牙语(拉美/西班牙)+ 日语(四柱推命本土市场) |

### 1.2 v1 明确不做

- **德 / 法 / 意 / 阿拉伯 / 东南亚语种** — 八字品类认知度极低,翻译成本高 ROI 低
- **App 内语言切换 UI** — v1 跟随系统语言,v2 加 Settings 页 + `X-QiCompass-Lang` 发送
- **阿拉伯语 RTL 布局** — 涉及交互重设计,v1 不做
- **打包自定义字体** — 系统字体 fallback 足够

### 1.3 战略依据(简版)

#### 为什么不一次性做 8 种语言

- "海外非华人主力市场"= 北美 + 西欧 + 澳洲,**英文一种已覆盖 65-70%**
- 加德/法/意 = 边际覆盖 15-20%,但翻译 + RTL + 字体 + LLM 调优 = 每语种 4-6 周
- 加阿拉伯/东南亚 = 边际覆盖 < 10%,且八字认知度近乎零
- 现代消费 App 国际化金标准(Calm/Headspace/Co-Star/Notion)全部英文先发 3-5 年,验证 PMF 后才加语种
- **8 种语言盲翻陷阱**:v1 阶段不知道哪些术语本地用户能理解,8 套返工

#### 为什么"AI 写代码方便"不解决 i18n 难题

工程只占 i18n 工作量 ~20%,水面下 80% 是:
- 翻译质量保证(术语词典 + 人工校对)40%
- LLM 跨语言调优(prompt 模板 + 测试)20%
- 字体 / RTL / 文化适配 10%
- 持续维护 10%

#### 八字海外 PMF 仍是开放命题(关键风险)

- 美区 App Store BaZi 类 App 都是独立开发者作品,**无头部标杆**
- FateTell(直接对标 QiCompass):25K 下载 / ~$4K ARR(独立开发者标准下也是下限附近)
- FateTell 创始人自己在 r/SideProject 焦虑"too niche",在知乎找曝光 = **仍在找 PMF,不是已找到 PMF**
- 25K 下载来源主要是中文科技媒体曝光(36 氪 / 知乎 / KrAsia),**主触达仍是华人受众**,不是海外非华人

#### QiCompass 真正的 40 倍杠杆(不是 i18n)

按 ROI 排序,以下杠杆比"加语言"高 10-40 倍:
1. 病毒内容营销(TikTok/YouTube/IG 100 万播放级)
2. KOL 合作(西方玄学网红背书)
3. App Store ASO + 关键词卡位
4. 品类教育("Chinese Astrology = 新塔罗")
5. 商业模式创新
6. 产品差异化(专业深度 vs FateTell)

**v1 i18n 投入应控制在 12-17 天(2.5-3.5 周),更多精力应投到内容营销 + 差异化**

---

## 2. 执行层 16 个决策汇总

### 后端线

#### 决策 1:翻译责任层 = 方案 3b

**结论**:后端按 `Accept-Language` header 解析 language,API Response 显式返回对应语言 + 术语 `id`。

**理由**:
- API schema 稳定(加语言不改 schema)
- 翻译质量集中后端管理
- 前端零翻译逻辑(只显示)
- 缓存键自然加 language 维度

**API 响应形状示例**:
```json
{
  "day_master": {
    "id": "jia_wood",
    "text": "Jia Wood"
  },
  "shishen_gan": {
    "id": "zheng_guan",
    "text": "Direct Officer"
  },
  "interpretation": "Your Day Master is Jia Wood..."
}
```

---

#### 决策 2:API 契约 = 方案 4(Accept-Language + X-QiCompass-Lang 混合)

**结论**:双 header fallback。`X-QiCompass-Lang` 优先(显式产品语言),`Accept-Language` fallback(系统偏好)。

**后端解析层**(`backend/app/api/language.py` 新建):
```python
from fastapi import Request
from typing import Final

SUPPORTED_LANGUAGES: Final[set[str]] = {"zh", "en"}  # 未来扩展: {"zh", "en", "es", "ja"}
DEFAULT_LANGUAGE: Final[str] = "zh"

def resolve_language(request: Request) -> str:
    """
    解析语言:优先 X-QiCompass-Lang(产品显式覆盖,v2 用),
    fallback 到 Accept-Language(系统偏好,v1 用)。
    未注册的语言 fallback 到 DEFAULT_LANGUAGE。
    """
    # 1. 优先读 X-QiCompass-Lang
    override = request.headers.get("x-qicompass-lang")
    if override and override.lower() in SUPPORTED_LANGUAGES:
        return override.lower()
    # 2. Fallback 读 Accept-Language
    accept = request.headers.get("accept-language", "")
    if accept:
        primary = accept.split(",")[0].split("-")[0].strip().lower()
        if primary in SUPPORTED_LANGUAGES:
            return primary
    return DEFAULT_LANGUAGE
```

**iOS v1 阶段行为**:
- 不发 `X-QiCompass-Lang` header(跟随系统)
- `URLSession` 默认带 `Accept-Language`(从 `NSLocale.current` 推断)
- v2 阶段做 App 内语言切换时再加 `httpAdditionalHeaders["X-QiCompass-Lang"] = userOverride`

**v1 trade-off**(接受):
- 海外华人 iPhone 系统英文 → 他会拿到英文 QiCompass(即使他想要中文)
- v1 不解决,等 v2 App 内切换

---

#### 决策 3:缓存键加 language 维度

**当前键**:`(content_hash, module, prompt_version, target_date)`
**新键**:`(content_hash, module, prompt_version, language, target_date)`

**4 个细节决策**:

| 细节 | 决策 |
|---|---|
| 1. language 值类型 | 规范化值(`en` / `zh`),不用原始 header 字符串 |
| 2. 加新语言老缓存 | 不动,自动隔离(language 维度区分) |
| 3. SwiftData nil 老缓存 | 视为 "zh"(因为 v1 前所有缓存都是中文) |
| 4. prompt_version 跨语言 | 全局同步(加语言时所有语言 prompt_version +1) |

---

#### 决策 4:prompt 模板按语言分支 = 方案 B(外部 Markdown 文件)

**结论**:模板从 `prompts.py` 硬编码拆到 `prompts/{lang}/{module}_v{ver}.md` 文件。

**目录结构**:
```
backend/app/ai/prompts/
├── zh/
│   ├── bazi_deep_v2.md
│   ├── bazi_deep_free_v2.md
│   ├── bazi_deep_paid_v2.md
│   ├── compatibility_v2.md
│   ├── compatibility_free_v2.md
│   ├── compatibility_paid_v2.md
│   ├── daily_fortune_v2.md
│   └── _special_pattern_suffix_v2.md
└── en/
    ├── bazi_deep_v2.md
    ├── bazi_deep_free_v2.md
    ├── bazi_deep_paid_v2.md
    ├── compatibility_v2.md
    ├── compatibility_free_v2.md
    ├── compatibility_paid_v2.md
    ├── daily_fortune_v2.md
    └── _special_pattern_suffix_v2.md
```

**`prompts.py` 改造核心代码**:
```python
from pathlib import Path
from functools import lru_cache
import logging

logger = logging.getLogger(__name__)
PROMPTS_DIR = Path(__file__).parent / "prompts"

@lru_cache(maxsize=None)
def _load_template(module: str, language: str, version: int) -> str:
    """加载模板并内存缓存。缺失时 fallback 到 zh(显式 log warning,不静默)。"""
    primary_path = PROMPTS_DIR / language / f"{module}_v{version}.md"
    if primary_path.exists():
        return primary_path.read_text(encoding="utf-8")
    # fallback 到 zh(语言模板未提供时降级)
    fallback_path = PROMPTS_DIR / "zh" / f"{module}_v{version}.md"
    if fallback_path.exists():
        logger.warning(
            f"prompt 模板 {module} v{version} 缺 {language} 版本,fallback 到 zh"
        )
        return fallback_path.read_text(encoding="utf-8")
    raise FileNotFoundError(
        f"prompt 模板缺失: {module} v{version}(both {language} and zh)"
    )

def render_prompt(module: str, context: dict, language: str = "zh") -> str:
    """渲染 prompt:按 module + language 加载模板,填充 context。

    Args:
        module: 7 module 之一
        context: prompt 渲染负载(必须含 REQUIRED_FIELDS[module] 所有字段,
                 context 数据本身已按 language 翻译过)
        language: 目标语言代码("zh" / "en" / 未来扩展)

    Returns:
        完整 provider-neutral prompt 字符串(目标语言)
    """
    validate_context(module, context)
    version = PROMPT_VERSIONS[module]
    template = _load_template(module, language, version)
    rendered = template.format_map(_StrictFormatDict(context))
    # 从格诚实降级(bazi_deep 系列三个 module 共用 suffix)
    if (module in ("bazi_deep", "bazi_deep_free", "bazi_deep_paid")
            and context.get("day_master_strength") == "special_pattern"):
        suffix = _load_template("_special_pattern_suffix", language, version)
        rendered += suffix
    return rendered
```

**实施注意**:
- 当前 `prompts.py:281-289` 的 `_TEMPLATES` 全局字典要删除,改成动态加载
- 所有引用 `_TEMPLATES[xxx]` 的代码改成 `_load_template(...)`
- 实施前先 `grep "_TEMPLATES"` 看影响范围

---

#### 决策 9:八字术语英文翻译表 = Joey Yap 体系

**结论**:以 [Joey Yap](https://www.joeyyap.com) 体系为事实标准,拼音直用干支,术语意译为主少数拼音。

**翻译表文件**:`backend/app/engine/term_translations.py` 新建

```python
"""八字术语翻译表(Joey Yap 体系为事实标准)。

源:Joey Yap《The Ten Gods》+ joeyyap.com 公开 tutorial + Imperial Harvest 参考
所有术语必须显式注册,未注册的术语抛 KeyError(显式失败,不静默返回中文)。
"""

from typing import Final

# 天干 / 地支 → 拼音直用(英文八字圈通用)
HEAVENLY_STEMS_EN: Final[dict[str, str]] = {
    "甲": "Jia", "乙": "Yi", "丙": "Bing", "丁": "Ding",
    "戊": "Wu", "己": "Ji", "庚": "Geng", "辛": "Xin",
    "壬": "Ren", "癸": "Gui",
}

EARTHLY_BRANCHES_EN: Final[dict[str, str]] = {
    "子": "Zi", "丑": "Chou", "寅": "Yin", "卯": "Mao",
    "辰": "Chen", "巳": "Si", "午": "Wu", "未": "Wei",
    "申": "Shen", "酉": "You", "戌": "Xu", "亥": "Hai",
}

# 十神(Joey Yap 体系)
TEN_GODS_EN: Final[dict[str, str]] = {
    "比肩": "Companion",
    "劫财": "Rob Wealth",
    "食神": "Eating God",
    "伤官": "Hurting Officer",
    "偏财": "Indirect Wealth",
    "正财": "Direct Wealth",
    "正官": "Direct Officer",
    "七杀": "Seven Killings",
    "偏官": "Seven Killings",  # 同义,Joey Yap 统一用 Seven Killings
    "正印": "Direct Resource",
    "偏印": "Indirect Resource",
}

# 神煞(20 个清单,11 吉 + 9 凶,意译为主少数拼音)
SHENSHA_EN: Final[dict[str, str]] = {
    # 吉神(11)
    "天乙贵人": "Heavenly Nobleman",
    "太极贵人": "Taiji Nobleman",
    "天德贵人": "Heavenly Virtue",
    "月德贵人": "Monthly Virtue",
    "文昌贵人": "Academic Star",
    "桃花": "Peach Blossom",
    "驿马": "Traveling Horse",
    "金舆": "Golden Carriage",
    "福星贵人": "Fortune Star",
    "天厨贵人": "Heavenly Kitchen",
    "三奇贵人": "Three Nobles",
    # 凶神(9)
    "华盖": "Floral Canopy",
    "红艳": "Red Charm",
    "学堂": "Academy",
    "将星": "General Star",
    "血刃": "Blood Blade",
    "劫煞": "Robbing Sha",
    "灾煞": "Disaster Sha",
    "亡神": "Wandering Spirit",
    "孤辰寡宿": "Lonely Star",
}

# 纳音(30 个,英文八字圈不深入教,统一用 "Nayin" + 拼音)
# 实施时按 lunar_python 输出的 30 个纳音名称建表
NAYIN_EN: Final[dict[str, str]] = {
    "海中金": "Sea of Metal",
    "炉中火": "Fire in the Furnace",
    # ... 完整 30 项,实施时补齐
}

# 其他核心术语
CORE_TERMS_EN: Final[dict[str, str]] = {
    "日主": "Day Master",
    "十神": "Ten Gods",
    "大运": "Luck Pillar",
    "流年": "Annual Pillar",
    "流月": "Monthly Pillar",
    "纳音": "Nayin",
    "天干": "Heavenly Stems",
    "地支": "Earthly Branches",
    "五行": "Five Elements",
    "木": "Wood", "火": "Fire", "土": "Earth",
    "金": "Metal", "水": "Water",
    "喜用神": "Favorable Element",
    "忌神": "Unfavorable Element",
    "神煞": "Special Stars",
    "命宫": "Life Palace",
    "旺衰": "Strength",
    "调候": "Adjustment",
    "扶抑": "Support and Suppress",
    "从格": "Special Pattern",
    "专旺": "Dominant Pattern",
    "格局": "Structure",  # MVP 砍掉,但保留翻译备用
    "年柱": "Year Pillar",
    "月柱": "Month Pillar",
    "日柱": "Day Pillar",
    "时柱": "Hour Pillar",
}

# 翻译注册表(语言 → {中文术语 → 目标语言术语})
TERM_TRANSLATIONS: Final[dict[str, dict[str, str]]] = {
    "zh": {},  # 中文 identity map 不需要(直接返回原文)
    "en": {
        **HEAVENLY_STEMS_EN,
        **EARTHLY_BRANCHES_EN,
        **TEN_GODS_EN,
        **SHENSHA_EN,
        **NAYIN_EN,
        **CORE_TERMS_EN,
    },
}


def translate_term(zh_term: str, target_language: str) -> str:
    """术语翻译:中文源 → 目标语言。

    未注册的术语抛 KeyError(显式失败,不静默返回中文)。
    中文目标语言直接返回原文(identity)。
    """
    if target_language == "zh":
        return zh_term
    table = TERM_TRANSLATIONS.get(target_language)
    if table is None:
        raise KeyError(
            f"未注册的目标语言: {target_language}"
            f"(支持的 languages: {list(TERM_TRANSLATIONS.keys())})"
        )
    if zh_term not in table:
        raise KeyError(
            f"术语 '{zh_term}' 未注册 {target_language} 翻译"
            f"(需在 term_translations.py 补齐)"
        )
    return table[zh_term]
```

**5 个细节决策**:

| 争议点 | 决策 |
|---|---|
| 天干地支 | 拼音直用(Jia/Yi/Zi/Chou) |
| 纳音 | 翻译 + 保留 "Nayin" 作为品类词 |
| 神煞 | 意译为主,少数拼音(Taiji Nobleman) |
| 大运 | "Luck Pillar"(Joey Yap 标准) |
| 错误处理 | 严格抛 KeyError,不静默 fallback 到中文 |

**实施时补充**:
- 纳音完整 30 项(参考 `backend/app/engine/pillars.py` 实际输出)
- 神煞的 20 个清单核对(参考 CLAUDE.md 神煞清单 + `backend/app/engine/shensha.py`)
- 实施时如发现遗漏的术语,在 PR 里同步补齐 + 写明来源

---

#### 决策 10:Module / prompt_version schema 演化

**结论**:`InterpretResponse` 加 `language` 字段(后端是 language 事实源,客户端从 Response 取)。

**后端 schema 改造**(`backend/app/models/interpret.py:92-110`):
```python
class InterpretResponse(BaseModel):
    """POST /api/interpret 响应。"""
    interpretation: str
    prompt_version: int
    cached: bool
    generated_at: datetime
    provider: Literal["anthropic", "openai"]
    model: str
    language: str = Field(  # 新增
        ...,
        description="本次解读实际使用的语言(从 Accept-Language 解析,"
                   "客户端存入 SwiftData 缓存键对齐用)"
    )

    @field_serializer("generated_at")
    def _serialize_generated_at(self, dt: datetime) -> str:
        return dt.replace(microsecond=0).isoformat()
```

**`InterpretRequest` 不加 language** — 继续从 header 解析(决策 2)。

**后端缓存层改造**:SQLite 缓存表加 `language TEXT NOT NULL` 列,缓存键加 language 维度。

---

### iOS 线

#### 决策 5:xcstrings 组织 = 单文件 + 模块前缀 key 命名

**文件**:`ios/QiCompass/QiCompass/Resources/Localizable.xcstrings`(保留现有,扩展)

**key 命名规则**:`{module}.{scope}.{name}`(点分隔)

| 模块 | 示例 key |
|---|---|
| Onboarding | `onboarding.welcome.sutra` / `onboarding.cta.start` |
| DeepAnalysis | `deepanalysis.header.dayMaster` / `deepanalysis.shensha.title` |
| DailyFortune | `dailyfortune.header.lunarLabel` / `dailyfortune.section.todayTrend` |
| Compatibility | `compatibility.header.contextLabel` / `compatibility.chapter.exchange` |
| Common | `common.button.close` / `common.error.network` |

---

#### 决策 6:SwiftUI 本地化 API 风格 = `String(localized:)` + 自定义 `L10n` 枚举

**文件**:`ios/QiCompass/QiCompass/L10n/L10n.swift` 新建

```swift
/// 类型安全的本地化 key 引用。
/// 替代 SwiftUI 的 Text("硬编码中文") 反模式,避免 LocalizedStringKey 类型推断歧义。
enum L10n {
    enum Onboarding {
        static let welcomeSutra = String(localized: "onboarding.welcome.sutra")
        static let ctaStart = String(localized: "onboarding.cta.start")
    }
    enum DeepAnalysis {
        static let shenshaTitle = String(localized: "deepanalysis.shensha.title")
    }
    enum DailyFortune {
        static let lunarLabel = String(localized: "dailyfortune.header.lunarLabel")
    }
    enum Compatibility {
        static let contextLabel = String(localized: "compatibility.header.contextLabel")
    }
    enum Common {
        static let closeButton = String(localized: "common.button.close")
        static let networkError = String(localized: "common.error.network")
    }
}
```

**调用示例**:
```swift
Text(L10n.Onboarding.welcomeSutra)    // 替代 Text("不知命,无以为君子也")
Text(L10n.DailyFortune.lunarLabel)    // 替代 Text("农历")
```

**批量替换策略**:
1. 新建 `L10n.swift` 骨架
2. 逐个 View 文件扫描硬编码中文,提取为 key
3. xcstrings 同步加 key + zh-Hans + en 双语
4. View 替换为 `L10n.xxx.yyy` 引用

---

#### 决策 7:DateFormatter locale = 农历永远 zh_CN,公历按 user locale

**文件**:`ios/QiCompass/QiCompass/L10n/BaziDateFormatter.swift` 新建

```swift
/// 八字 App 的日期格式化策略。
///
/// 产品决策:
/// - 农历永远用中文(zh_CN)——农历是术语,英文用户看到 "正月" 比看到 "Lunar January"
///   更能感知到这是 Chinese Astrology,符合 "专业不忽悠" Memorable Thing
/// - 公历按 user locale——本地化日期格式(2026/08/12 vs 08/12/2026)
/// - 流日柱(干支)永远中文——"甲子日" 不翻译,英文用户看到 "Jia Zi Day" 也是术语
enum BaziDateFormatter {
    /// 农历显示:永远 zh_CN
    static let lunar: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// 公历显示:按 user locale
    static let gregorian: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// 流日柱(干支):永远 zh_CN(术语)
    static let dayPillar: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}
```

**当前代码坑**:
- `ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneHeaderView.swift:14-16` 硬编码 `zh_CN`,迁移到 `BaziDateFormatter.lunar`

---

#### 决策 8:字体 fallback 链 = 系统 fallback + 自定义 BaziFont token

**文件**:`ios/QiCompass/QiCompass/Theme/BaziFont.swift` 新建

```swift
/// 八字 App 字体 token(DESIGN.md 强制:iOS 系统字体,不打包自定义字体)。
///
/// 利用 iOS 系统自动 fallback:
/// - Songti SC 不支持的字符(拉丁字母)自动 fallback 到系统衬线字体
/// - PingFang SC 不支持的字符(拉丁字母)自动 fallback 到 SF Pro Text
/// - v1 阶段只支持 zh+en,不需要复杂 fallback 链
enum BaziFont {
    /// 标题 / 八字衬线(Songti SC 系统自带)
    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// 正文(PingFang SC 中文 / SF Pro Text 英文,系统自动 fallback)
    static func body(size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 数字 tabular(SF Pro Text with tabular-nums,DESIGN.md 强制)
    static func number(size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}
```

**未来语言扩展策略**:

| 语言 | 字体策略 |
|---|---|
| v1 中文 | `.system(... design: .serif)` → Songti SC |
| v1 英文 | `.system(... design: .serif)` → New York(系统衬线) |
| 未来日文 | Songti SC 与日文汉字共用,iOS 自动 fallback Hiragino |
| 未来西班牙文 | Latin 字体默认支持,无改动 |
| 未来阿拉伯文(暂不做) | 系统自动 fallback Geeza Pro,但 RTL 布局要单独做 |

**实施坑**:`.monospacedDigit()` 在衬线字体上可能行为不一致,实施时测试数字对齐。

---

## 3. iOS SwiftData 改造

### `InterpretationCache.swift` 加 language 字段

**文件**:`ios/QiCompass/QiCompass/Models/InterpretationCache.swift`

```swift
@Model
final class InterpretationCache {
    @Attribute(.unique) var id: UUID
    var contentHash: String
    var module: String
    var promptVersion: Int
    var language: String?  // 新增(optional,Q13 决策:nil 视为 "zh")
    var targetDate: Date?
    var provider: String?
    var model: String?
    var interpretation: String
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        contentHash: String,
        module: String,
        promptVersion: Int,
        language: String? = nil,  // 默认 nil,向后兼容老 init 调用
        targetDate: Date? = nil,
        provider: String? = nil,
        model: String? = nil,
        interpretation: String,
        generatedAt: Date = .now
    ) {
        self.id = id
        self.contentHash = contentHash
        self.module = module
        self.promptVersion = promptVersion
        self.language = language
        self.targetDate = targetDate
        self.provider = provider
        self.model = model
        self.interpretation = interpretation
        self.generatedAt = generatedAt
    }
}
```

**字段类型选择**:**Optional (`String?`)** ← 选这个

- 老数据自动 nil = "zh"(Q13 决策)
- SwiftData schema 演化最小,符合 D1"不用 VersionedSchema"

### `InterpretationCacheStore.swift` 改造

```swift
func getLatest(
    contentHash: String,
    module: String,
    targetDate: Date?,
    language: String,  // 新增参数
    identity: AIIdentity
) throws -> InterpretationCache? {
    let desc = FetchDescriptor<InterpretationCache>(
        predicate: #Predicate {
            $0.contentHash == contentHash && $0.module == module
        }
    )
    let results = try context.fetch(desc)
    let hit = results
        .filter { cache in
            let cacheLang = cache.language ?? "zh"  // nil 视为 zh
            return cacheLang == language
                && /* targetDate + provider + model 条件不变 */
                /* ... */
        }
        .max(by: { $0.promptVersion < $1.promptVersion })
    return hit
}

func upsert(
    contentHash: String,
    module: String,
    promptVersion: Int,
    language: String,  // 新增参数
    targetDate: Date?,
    provider: String,
    model: String,
    interpretation: String,
    generatedAt: Date
) throws {
    // Predicate + filter 加 language 匹配(同样 nil 视为 zh)
    // ...
}
```

### `AppLanguage` 当前语言计算

**文件**:`ios/QiCompass/QiCompass/L10n/AppLanguage.swift` 新建

```swift
/// 当前 App 语言(基于系统 locale,v1 阶段无 App 内切换)。
///
/// 规范化为 "zh" / "en" / 未来 "ja" / "es"。
/// 未知 locale fallback 到 "zh"(DEFAULT_LANGUAGE)。
///
/// v2 阶段加 App 内语言切换时,改为 userPreference ?? systemLanguage。
enum AppLanguage {
    static let supported: Set<String> = ["zh", "en"]
    static let defaultLanguage = "zh"

    static var current: String {
        let raw = Locale.current.language.languageCode?.identifier ?? defaultLanguage
        return supported.contains(raw) ? raw : defaultLanguage
    }
}
```

调用:
```swift
let cache = try store.getLatest(
    contentHash: hash,
    module: module,
    targetDate: targetDate,
    language: AppLanguage.current,  // 系统语言
    identity: identity
)
```

---

## 4. 实施计划(11 个 slice,按依赖排序)

| # | Slice | 工作量估算 | 依赖 | 文件 |
|---|---|---|---|---|
| **P1** | 后端 `term_translations.py` — 八字术语翻译表(zh/en,Joey Yap 体系,~80 术语) | 2-3 天 | 无 | `backend/app/engine/term_translations.py`(新建) |
| **P2** | 后端 `language.py` — Accept-Language + X-QiCompass-Lang 双 header 解析层 | 0.5 天 | 无 | `backend/app/api/language.py`(新建) |
| **P3** | 后端 `prompts/zh/` + `prompts/en/` — 拆分现有 7 模板为 Markdown 文件(先迁移中文,英文先建空骨架) | 1-2 天 | P1 | `backend/app/ai/prompts/{zh,en}/*.md` |
| **P4** | 后端 `prompts.py` 改造 — 动态加载 + `render_prompt(module, context, language)` | 0.5 天 | P3 | `backend/app/ai/prompts.py` |
| **P5** | 后端 `interpret.py` — `InterpretResponse` 加 `language` 字段 + 路由层 wiring + context 数据按 language 翻译 | 1 天 | P2 P4 | `backend/app/models/interpret.py` + `backend/app/api/routes/interpret.py` |
| **P6** | 后端 SQLite 缓存表 — 加 `language` 列 + 缓存键加 language 维度 | 0.5 天 | P5 | `backend/app/db/*`(实施前 grep 确认路径) |
| **P7** | 后端 i18n 集成测试 — 模拟 Accept-Language: en 验证全链路 | 0.5 天 | P1-P6 | `backend/tests/test_i18n.py`(新建) |
| **i1** | iOS `BaziFont.swift` + `BaziDateFormatter.swift` + `L10n.swift` + `AppLanguage.swift` 骨架 | 0.5 天 | 无 | `ios/QiCompass/QiCompass/{Theme,L10n}/*.swift` |
| **i2** | iOS xcstrings 录入 — 当前所有硬编码中文提取为 key(zh + en 双语) | **3-5 天**(最大工作量) | i1 | `ios/QiCompass/QiCompass/Resources/Localizable.xcstrings` |
| **i3** | iOS SwiftData `InterpretationCache` 加 `language` 字段 + Store + APIClient 改造 | 1 天 | P5 i1 | `ios/QiCompass/QiCompass/{Models,Services,Networking}/*.swift` |
| **i4** | iOS View 文件批量替换硬编码 → `L10n.xxx.yyy` | 2-3 天 | i2 | `ios/QiCompass/QiCompass/Features/**/*.swift` |
| **i5** | iOS 英文版 UI 测试 + 视觉调优(字体 fallback / 排版断行 / 术语本地化测试) | 2-3 天 | i4 | (跨多个文件) |

**v1 总工作量:12-17 天**(2.5-3.5 周全职)

### Slice 推进顺序建议

**Sprint 1(第 1 周)**:P1 → P2 → P3 → P4
- 目标:后端 prompt 模板分支 + 翻译表地基就绪
- 验收:`pytest` 通过 + 单元测试覆盖英文模板渲染

**Sprint 2(第 2 周)**:P5 → P6 → P7 → i1 → i3
- 目标:后端 API 完成,SwiftData schema 完成
- 验收:后端 `/api/interpret` 接受 Accept-Language: en 返回英文响应 + iOS SwiftData 不破坏老缓存

**Sprint 3(第 3 周)**:i2 → i4 → i5
- 目标:iOS UI 英文版可用
- 验收:iOS 模拟器系统语言切换到英文,App UI 完整英文,无中文残留

### 每个 Slice 实施前的检查清单

实施每个 slice 前先做:
- [ ] `grep` 当前代码看实际影响范围(尤其 `_TEMPLATES` / `DateFormatter` / 硬编码中文)
- [ ] 查 CLAUDE.md 全局约束(错误显式传播 / 不擅自加依赖 / Git 三段式 commit)
- [ ] 写单元测试覆盖新代码
- [ ] PR 描述里贴这份 plan 文档的对应决策编号(便于 review)

---

## 5. v1 范围外明确不做(防止 scope creep)

| 项目 | 推迟到 |
|---|---|
| 日语 UI 翻译 | v2(数据驱动) |
| 西班牙语 UI 翻译 | v2(数据驱动) |
| 德/法/意 UI 翻译 | v3+(除非数据强烈支持) |
| 阿拉伯语 UI + RTL 布局 | 不做(除非战略调整) |
| 东南亚单一语种 UI 翻译 | 不做(市场太散) |
| App 内语言切换 Settings 页 | v2 |
| 打包自定义字体 | 不做(DESIGN.md 决策) |
| VersionedSchema / SchemaMigrationPlan | 不做(D1 决策) |
| singleflight / Redis AI 缓存 | v2+ |
| 多人命盘管理 UI | v2 |

---

## 6. 关键参考资料

### 八字术语英文权威
- [Joey Yap - The Ten Gods](https://books.google.com/books/about/The_Ten_Gods.html?id=NAr0nQEACAAJ)
- [Joey Yap Ten Gods Tutorial](https://www.joeyyap.com/tutorial/tutorial-details.asp?tid=28)
- [Jerry King - The Ten Gods Handbook](https://whitedragonhome.com/four-pillars-of-destiny-the-ten-gods-handbook/)
- [BaziCalculator vs Joey Yap 术语对比](https://www.bazicalculator.io/learn/bazi-calculator-vs-joey-yap)
- [Imperial Harvest - 10 Gods 参考](https://imperialharvest.com/blog/10-gods/)

### 美区八字 App 市场对照
- [FateTell - Chinese Astrology](https://apps.apple.com/us/app/fatetell-chinese-astrology/id6752552096)
- [FateTell 创始人知乎专访](https://zhuanlan.zhihu.com/p/2010853635978961770)
- [FateTell 创始人 r/SideProject 帖子](https://www.reddit.com/r/SideProject/comments/1rseprb/)
- [My BaZi Astrology](https://apps.apple.com/us/app/my-bazi-astrology/id6758286066)
- [HelloBot - Astrology & Tarot(综合玄学)](https://apps.apple.com/us/app/hellobot-astrology-tarot/id1294957719)
- [K-Saju Reddit r/SideProject](https://www.reddit.com/r/SideProject/comments/1rc1ayq/)

### 现代消费 App 国际化金标准
- Co-Star(2017 创立,2021 才加德法意 — 英文先发 4 年)
- The Pattern(2019 创立,2022 才扩 — 英文先发 3 年)
- Calm(2012 创立,2015 才加第一批本地化)
- Headspace(2010 创立,2016 才扩)
- Notion(2013 创立,2018 才扩)

### 项目内对齐文档
- `CLAUDE.md`(全局约束 + 项目特定约束)
- `bazi-app-design-doc.md`(主设计文档)
- `命理引擎设计决策.md`(命理层决策 D1/D2/D3)
- `DESIGN.md`(视觉设计系统)
- `USER_STORIES.md`(用户故事 + 验收标准)
- `MONETIZATION.md`(付费系统设计)

---

## 7. 风险与未解决问题

### 7.1 已识别风险

1. **海外 PMF 未验证**
   - 八字在海外非华人市场目前无头部标杆,FateTell 25K 下载不算商业验证
   - **缓解**:v1 上线后重点观测 App Store Connect 国家数据 + D7 留存 + 付费转化
   - **触发条件**:如果 v1 上线 60 天英文版 organic 自然下载 < 10/天,**应该转向内容营销而非加语言**

2. **英文八字术语无统一标准**
   - Joey Yap 体系是事实标准但非学术权威,术语选择可能不被所有英文八字用户认可
   - **缓解**:在 `term_translations.py` 文件头标注术语来源 + PR review 时邀请懂英文八字的用户验证

3. **LLM 跨语言质量**
   - Claude/GPT 对八字的理解依赖中文训练数据,英文输出可能跑偏
   - **缓解**:P7 集成测试包含 LLM 英文输出质量评估(术语使用准确性 + 八字逻辑正确性)

4. **盲翻陷阱**
   - v1 阶段不知道哪些术语英文用户能理解
   - **缓解**:v1 上线后收集英文用户反馈,迭代术语翻译表(prompt_version +1 触发缓存失效)

### 7.2 未解决的问题(留给后续 grill 或实施时发现)

- 后端 SQLite 缓存表具体实现路径(实施 P6 前需 grep 确认)
- `_TEMPLATES` 全局字典的所有引用点(P4 实施前 grep)
- iOS `provider/model` 字段的旧数据迁移策略(实施 i3 时确认)
- 农历显示是否真要永远中文(决策 7 是产品决策,实施后可基于用户反馈调整)

---

## 8. 决策追溯(为什么做这些选择)

### 为什么不一次性做 8 种语言

**用户最初诉求**:加日/德/法/意/西/阿拉伯/东南亚语种,一次性上。

**拷打过程**:
1. 用户动机:"分散下注,中文市场太卷"
2. 反驳:海外华人只占海外人口极小比例,真正目标是海外非华人市场
3. 数据对照:英文一种已覆盖海外玄学消费主力 65-70%,加 7 种语言边际覆盖 30% 但成本翻 4-5 倍
4. PMF 拷问:八字在海外非华人认知度极低,FateTell(直接对标)25K 下载 / ~$4K ARR 远未达商业验证
5. 工程拷问:"AI 写代码方便"只覆盖 i18n 工作量 20%,水面下 80% 是翻译质量 + LLM 调优 + 本地化测试
6. 时机拷问:v1 阶段做 8 种语言 = 锁死迭代速度到 1/8 + 8 套盲翻返工

**最终决策**:v1 中文 + 英文,架构开口子,内容只投入做英文

### 为什么用方案 3b(后端按 Accept-Language 返回对应语言 + id)

- 方案 1(后端字段膨胀)被淘汰:加语言 schema 膨胀
- 方案 2(前端翻译一切)被淘汰:前端维护 N 种词典,版本同步麻烦
- 方案 3b 胜出:API schema 稳定 + 翻译质量集中 + 前端零翻译逻辑

### 为什么用方案 4(双 header 混合)

- 方案 1(纯 Accept-Language)被淘汰:v2 加 App 内切换时无法覆盖系统语言
- 方案 2(纯 query param)被淘汰:污染 URL
- 方案 4 胜出:v1 阶段不发 X-QiCompass-Lang(零 iOS 工作量),v2 加 App 内切换时不动后端

### 为什么用方案 B(外部 Markdown 文件)

- 方案 A(内嵌分支)被淘汰:prompts.py 文件爆炸(406 行 × N 语言)
- 方案 C(数据库)被淘汰:版本控制弱,代码 review 难
- 方案 B 胜出:模板/代码分离,翻译团队友好,加语言只加目录

### 为什么选 Joey Yap 体系

- Jerry King 已故,影响力衰减
- BaziCalculator 通俗重包装偏离"专业"定位
- Imperial Harvest 跟随 Joey Yap
- Joey Yap 是英文八字圈事实主导(出书最多 + 流量最大 + 海外华人 + 西方严肃学习者都熟悉)

---

**文档版本**:v1.0(2026-08-12 grill-me 完成)
**下次 review 时机**:v1 上线后 60-90 天,基于 App Store Connect 数据决定是否启动第二波语言
