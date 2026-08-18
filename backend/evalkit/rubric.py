"""evalkit L3 裁判 rubric(S05)。

把 spikes/prompt_validation/eval_prompt.md 的 7 维 rubric 代码化。
RUBRIC_VERSION 与 PROMPT_VERSIONS 同思路:rubric 改必 bump,
老分数不与新分数比(JUDGE_MODEL/RUBRIC_VERSION 进 RunIdentity)。

「神煞准确」「无硬性格局」「严格遵守后端喜忌」「special_pattern 诚实」
四维已被 S03 的 L2 确定性判据覆盖——保留做交叉验证:L2 说过、L3 也说过的
是高置信度问题;只有 L3 说的要人工判断是真问题还是裁判幻觉。
"""

from __future__ import annotations

import json
from typing import Any

RUBRIC_VERSION: int = 1

_SCORE_KEYS: tuple[str, ...] = (
    "五行完整",
    "十神配置",
    "神煞准确",
    "大运流年",
    "无硬性格局",
    "严格遵守后端喜忌",
    "special_pattern_诚实",
)

# JSON 输出 schema 的大括号用 {{ }} 转义(str.format_map 还原为单花括号),
# 与 app/ai/prompts.py v1 模板同做法。
JUDGE_TEMPLATE = """你是一位精通中国传统四柱八字命理的评审。请对以下 AI 生成的命书模块解读做质量评分。
**只输出结构化评分,不重写内容。**

被评模块: {module}

### 后端确定性 Ground Truth(命理引擎输出,不可篡改)

- 日主旺衰: {day_master_strength}
- 喜用五行: {favorable_elements}
- 忌讳五行: {unfavorable_elements}
- 五行统计: {element_balance}
- 神煞清单: {shensha_list}
- 当前大运: {current_luck_pillar}
- 当前流年: {current_year_pillar}
- 调候触发: {tiaoshou_applied}
- 从格特征: {pattern_hint}
- 十神(年干): {year_shishen_gan}
- 十神(月干): {month_shishen_gan}
- 十神(时干): {hour_shishen_gan}

### AI 生成的命书模块输出

{llm_response}

### 评分维度(每项 1-5 分)

请逐项打分,并给出扣分理由(分数 < 4 时必须说明):

1. **五行完整**(1-5): 是否完整覆盖日主强弱 + 各行数量 + 缺失行?
   - 5: 完整且准确 / 3: 部分覆盖 / 1: 漏行、数量错误
2. **十神配置**(1-5): 是否正确引用后端给的十神 + 关系正确?
   - 5: 正确引用全部十神 / 3: 引用部分十神 / 1: 自行造十神、关系错误
3. **神煞准确**(1-5): 是否提及后端查到的神煞 + 不超界?
   - 5: 准确引用,不超界 / 3: 引用部分 / 1: 编造未给的神煞
4. **大运流年**(1-5): 是否正确叙述童限过渡(index=0 空)+ 走势?
   - 5: 童限过渡正确 + 走势清晰 / 3: 走势提及,童限未提 / 1: 跳过 index=0、编造流年
5. **无硬性格局**(1-5): 是否用"命局呈现××倾向"叙事?
   - 5: 模糊叙事,无硬分类 / 3: 有暗示但未明说 / 1: 出现"正官格 / 偏印格"等硬分类
6. **严格遵守后端喜忌**(1-5): 是否不擅自改写 favorable/unfavorable?
   - 5: 完全遵守 / 3: 有偏差但方向一致 / 1: 自行加喜忌、改喜忌方向
7. **special_pattern_诚实**(仅 special_pattern 盘适用,普通盘 N/A):
   - 5: 明说"不入常格扶抑框架" + 不编造喜忌 / 3: 有暗示但不够明确 / 1: 隐藏降级、强行给喜忌

### 输出格式(严格 JSON,不要多余文字,不加 markdown 代码块围栏)

{{
  "scores": {{
    "五行完整": <1-5>,
    "十神配置": <1-5>,
    "神煞准确": <1-5>,
    "大运流年": <1-5>,
    "无硬性格局": <1-5>,
    "严格遵守后端喜忌": <1-5>,
    "special_pattern_诚实": "<1-5 或 N/A>"
  }},
  "overall": <适用维度平均,保留 1 位小数>,
  "failures": ["<扣分维度: 理由>", ...],
  "passed": <true/false, overall >= 4.0>
}}
"""


class _StrictFormatDict(dict):
    """str.format_map 的字典:缺失 key 时抛清晰 KeyError(不静默填空)。

    照抄 app/ai/prompts.py:_StrictFormatDict 的做法(rubric 独立实现,
    不 import 生产模块的私有类)。
    """

    def __missing__(self, key: str) -> str:  # type: ignore[override]
        raise KeyError(f"judge 模板占位符 {{{key}}} 在 context 中缺失")


def _format_elements(elements: list[str] | None) -> str:
    """五行列表 → 中文顿号串;空 = 从格喜忌留空(special_pattern)。"""
    if not elements:
        return "无(special_pattern 喜忌留空)"
    return "、".join(elements)


def _format_shensha(shensha: list[dict[str, Any]]) -> str:
    """神煞命中列表 → 「名(柱位)」串;空 = 无。"""
    if not shensha:
        return "无"
    return "、".join(f"{s['name']}({s.get('position', '?')})" for s in shensha)


def _format_luck_pillar(pillar: dict[str, Any] | None) -> str:
    """CurrentPillar 字段是 gan_zhi/start_year/end_year(models/bazi.py:128)。

    注意不是 start_age/end_age——chart_builder 为 chart 做过反查补 age,
    evalkit 直接喂 engine_result 不走那条链,用 year 区间展示。
    童限(index=0, gan_zhi="")显式标注,评分维度 4 要求裁判判断童限过渡。
    """
    if not pillar:
        return "无(童限内,index=0 为过渡)"
    gan_zhi = pillar.get("gan_zhi") or ""
    if not gan_zhi:
        return "童限过渡(index=0,大运未起)"
    start, end = pillar.get("start_year"), pillar.get("end_year")
    years = (f"(year {start}-{end})"
             if start is not None and end is not None else "")
    return f"{gan_zhi}{years}"


def build_judge_prompt(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> str:
    """组装裁判 prompt:ground truth 段(engine_result)+ 被评输出。

    engine_result 缺必需键 → KeyError 显式暴露(排盘结果不完整是上游 bug)。
    """
    pillars = engine_result["pillars"]
    context = _StrictFormatDict({
        "module": module,
        "day_master_strength": engine_result["day_master_strength"],
        "favorable_elements": _format_elements(
            engine_result["favorable_elements"]),
        "unfavorable_elements": _format_elements(
            engine_result["unfavorable_elements"]),
        "element_balance": json.dumps(
            engine_result["element_balance"], ensure_ascii=False),
        "shensha_list": _format_shensha(engine_result["shensha"]),
        "current_luck_pillar": _format_luck_pillar(
            engine_result.get("current_luck_pillar")),
        "current_year_pillar": engine_result.get("current_year_pillar") or "无",
        "tiaoshou_applied": "是" if engine_result["tiaoshou_applied"] else "否",
        "pattern_hint": engine_result.get("pattern_hint") or "无",
        "year_shishen_gan": pillars["year"]["shishen_gan"],
        "month_shishen_gan": pillars["month"]["shishen_gan"],
        "hour_shishen_gan": pillars["hour"]["shishen_gan"],
        "llm_response": json.dumps(
            parsed_output, ensure_ascii=False, indent=2),
    })
    return JUDGE_TEMPLATE.format_map(context)


def judge_score_keys() -> tuple[str, ...]:
    """7 维 key(结构校验与测试用)。"""
    return _SCORE_KEYS
