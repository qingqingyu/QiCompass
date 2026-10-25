"""daily_ask 模板注册与渲染(问事窗 S4b-1,2026-10-25)。

覆盖:注册与字段清单共享 / 字段上限锁值 / 三语加载渲染 / unknown_hour
放宽集渲染 / 缺盘面字段 422 / ask 专属字段超长 422 / 缺模板版本显式
FileNotFoundError。

ask 专属字段(daily_interpretation / ask_conversation / ask_mode_note /
user_question)由端点注入、不进 REQUIRED_FIELDS 的设计口径见
prompts.py 注释与 MONETIZATION.md §问事窗。
"""

from __future__ import annotations

import pytest

from app.ai.prompts import (
    _FIELD_CHAR_LIMITS,
    PROMPT_VERSIONS,
    REQUIRED_FIELDS,
    render_prompt,
)
from app.errors import InvalidInputError


def _daily_ask_context(**overrides) -> dict:
    ctx = {
        # 盘面字段(daily_fortune 同款清单)
        "day_master": "辛金", "day_master_element": "金",
        "day_master_strength": "balanced",
        "favorable_elements": "土、金", "unfavorable_elements": "木",
        "date": "2026年10月25日", "lunar_date": "九月十六",
        "day_pillar": "辛未", "day_stem": "辛", "day_stem_element": "金",
        "day_branch": "未", "day_branch_element": "土",
        "day_relation": "比肩", "day_chong": "冲丑",
        "hour_pillars_with_relations": "子时(23-1) 比肩",
        "huangli_yi": "独立、立界", "huangli_ji": "争执、攀比",
        # ask 专属字段(服务端注入)
        "daily_interpretation": '{"headline": "比肩当值\\n同气相扶亦暗藏争夺"}',
        "ask_conversation": "（无）",
        "ask_mode_note": "首次提问，直接作答。",
        "user_question": "今天适合去谈判吗？",
    }
    ctx.update(overrides)
    return ctx


class TestDailyAskRegistration:
    def test_registered_with_version_1(self):
        assert PROMPT_VERSIONS["daily_ask"] == 1

    def test_required_fields_shares_daily_fortune_list(self):
        # 同一 list 对象:盘面契约与 daily_fortune 永不分叉
        assert (REQUIRED_FIELDS["daily_ask"]
                is REQUIRED_FIELDS["daily_fortune"])

    def test_ask_specific_fields_not_in_required(self):
        # iOS builder 不产这些键,进清单会让 check_prompt_sync 误报
        for field in ("user_question", "daily_interpretation",
                      "ask_conversation", "ask_mode_note"):
            assert field not in REQUIRED_FIELDS["daily_ask"]

    def test_ask_field_char_limits_registered(self):
        # 4 档上限显式锁值:daily_interpretation 恰等于默认 4096,行为测试
        # 区分不了「显式注册」与「碰巧默认」,须直锁字典条目
        for field, limit in (("user_question", 200),
                             ("daily_interpretation", 4096),
                             ("ask_conversation", 8192),
                             ("ask_mode_note", 300)):
            assert _FIELD_CHAR_LIMITS[field] == limit, field


class TestDailyAskRender:
    @pytest.mark.parametrize("language,marker", [
        ("zh", "流日推断"),
        ("zh-hant", "流日推斷"),
        ("en", "Four Pillars"),
    ])
    def test_render_three_languages(self, language, marker):
        rendered = render_prompt(
            "daily_ask", _daily_ask_context(), language=language)
        assert marker in rendered
        assert "今天适合去谈判吗" in rendered          # 问题注入
        assert "{user_question}" not in rendered        # 占位符全部填充
        assert "favorable_elements" not in rendered     # 模板不引用喜忌键名

    def test_render_unknown_hour_relaxed_set(self):
        # unknown_hour:S09 放宽的 3 个字段缺失,同一模板仍可渲染
        ctx = _daily_ask_context(day_master_strength="unknown_hour")
        for field in ("favorable_elements", "unfavorable_elements",
                      "hour_pillars_with_relations"):
            ctx.pop(field)
        rendered = render_prompt("daily_ask", ctx)
        # day_master_strength 值原样进 prompt(渲染层分支控制信号,不翻译);
        # 通用要求里的时辰未知诚实指令同模板在场(单模板设计的兜底约束)
        assert "unknown_hour" in rendered
        assert "出生时辰未知" in rendered

    def test_missing_chart_field_raises_422(self):
        ctx = _daily_ask_context()
        del ctx["day_pillar"]
        with pytest.raises(InvalidInputError, match="day_pillar"):
            render_prompt("daily_ask", ctx)

    @pytest.mark.parametrize("field,limit", [
        ("user_question", 200),
        ("ask_conversation", 8192),
        ("ask_mode_note", 300),
    ])
    def test_ask_field_over_limit_raises_422(self, field, limit):
        ctx = _daily_ask_context(**{field: "长" * (limit + 1)})
        with pytest.raises(InvalidInputError, match=field):
            render_prompt("daily_ask", ctx)

    def test_missing_template_version_raises(self):
        with pytest.raises(FileNotFoundError):
            render_prompt(
                "daily_ask", _daily_ask_context(), prompt_version=99)
