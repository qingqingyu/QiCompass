"""合盘 interpret 后置处理单测(2026-09-27:A/B 代号替换 + 干支接地观测)。

对应 app/api/interpret.py 的 `_replace_ab_labels` / `_log_offchart_ganzhi`:
prompt v4 之外的确定性兜底——LLM 违约在叙述里残留 standalone A/B 时代号被
替换为两人称呼;输出提及盘外干支时记 warning 观测(log-only,不拦截)。
末尾 TestRoutePostprocess 锁 interpret() 内 3 行接线(module 成员判定 +
名字取自 translated_context + 替换先于返回/缓存),防重构静默回归。
"""

from __future__ import annotations

import logging

from app.api.interpret import _log_offchart_ganzhi, _replace_ab_labels
from tests.fixtures.interpret_cases import COMPATIBILITY_CONTEXT


class TestReplaceAbLabels:

    def test_standalone_a_b_replaced(self):
        out = _replace_ab_labels(
            "A 倾向于先说结论，B 习惯先想清楚。", "你", "小林")
        assert out == "你倾向于先说结论，小林习惯先想清楚。"

    def test_no_space_variant(self):
        """代号后无空格(「A倾向于」)同样替换;有尾随空格则一并吞掉。"""
        out = _replace_ab_labels("A倾向于快,B 稳。", "你", "她")
        assert out == "你倾向于快,她稳。"

    def test_latin_words_not_touched(self):
        """Amanda / H1B 内部字母由环视保护,不误伤。"""
        text = "Amanda 与 H1B 不受影响,但 A 的节奏偏快"
        out = _replace_ab_labels(text, "你", "小林")
        assert "Amanda" in out and "H1B" in out
        assert "你 的节奏" in out or "你的节奏" in out

    def test_name_starting_with_letter_preserved(self):
        """名字首字符即该字母(如「A先生」)→ 正文里合规写出的名字保真,
        防止文本里的「A先生」被替换成「A先生先生」。
        (2026-09-28 机制更新:skip-guard → 名字遮罩——名字整体先换占位符,
        其字母退出代号轮视野;附带收益见 test_bare_code_replaced_when_name_letter。)"""
        out = _replace_ab_labels("A先生的盘面", "A先生", "小林")
        assert out == "A先生的盘面"
        # B 侧不受 A 名字影响
        out_b = _replace_ab_labels("B 稳", "A先生", "小林")
        assert out_b == "小林稳"

    def test_name_with_mid_standalone_letter_preserved(self):
        """名字中间含 standalone 字母(如「阿B」「小 A」)→ 同样保真,
        防止文本里出现的名字本身被二次替换成「阿阿B」
        (遮罩按名字整体保护,不分首字符还是中间)。"""
        # 阿B:B 前是 CJK(非字母数字)→ 名字内 standalone 命中 → 遮罩保真;
        # A 侧名字「你」无 standalone 字母,照常替换(吞代号后空格)
        assert _replace_ab_labels("阿B 的节奏,A 稳。", "你", "阿B") == "阿B 的节奏,你稳。"
        # 小 A:A 前是空格 → 同理遮罩保真;B 侧照常
        assert _replace_ab_labels("小 A,B 同频。", "小 A", "小林") == "小 A,小林同频。"

    def test_cross_axis_name_a_contains_b_letter(self):
        """交叉轴污染(2026-09-28 外部 review 实证):name_a 含 standalone B
        (「小B」)——老两轮实现里 A 轮注入的「小B」被 B 轮吃成「小丽」,
        A 的称呼变成 B 的称呼。单遍替换只扫原文不回扫,注入回流消失。"""
        out = _replace_ab_labels("A 倾向于先说结论，B 更慢热。", "小B", "丽")
        assert out == "小B倾向于先说结论，丽更慢热。"

    def test_cross_axis_spaced_variant(self):
        """同上,字母前带空格的变体(「阿 B」);老实现产出「阿 丽」。"""
        out = _replace_ab_labels("A 倾向于先说结论，B 更慢热。", "阿 B", "丽")
        assert out == "阿 B倾向于先说结论，丽更慢热。"

    def test_verbatim_name_in_text_not_eaten(self):
        """LLM 合规(prompt v4)在正文写出 name_a 本身时,名字内的 B 同样
        不被 B 轮吃掉——单遍替换只防注入回流,**原文里的「小B」**要靠遮罩
        保护(老实现此用例产出「小丽倾向于快」,交叉污染的原文侧变体)。"""
        out = _replace_ab_labels("小B 倾向于快，B 更慢热。", "小B", "丽")
        assert out == "小B 倾向于快，丽更慢热。"

    def test_reverse_direction_name_b_contains_a(self):
        """反方向(name_b 含 standalone A)老实现即安全(A 轮先跑不回扫),
        锁住防回归。"""
        out = _replace_ab_labels("A 倾向于先说结论，B 更慢热。", "明", "A君")
        assert out == "明倾向于先说结论，A君更慢热。"

    def test_bare_code_replaced_when_name_letter(self):
        """遮罩版比老 skip-guard 强:名字含代号字母时,裸代号不再整轴放弃
        (老实现两头都跳过,「A 倾向于」裸代号残留到用户眼前)。"""
        out = _replace_ab_labels("A先生稳，A 更快。", "A先生", "小林")
        assert out == "A先生稳，A先生更快。"
        out2 = _replace_ab_labels("A 倾向于先说结论，B 更慢热。", "A先生", "阿B")
        assert out2 == "A先生倾向于先说结论，阿B更慢热。"

    def test_mask_order_long_name_first_prefix_overlap(self):
        """前缀重叠场景的保真(条件遮罩后排序在此形态已不承重,锁定结果):
        name_a「小」不含 standalone 字母不遮,name_b「小B」整体遮——
        「小B」的 B 不裸露,原样保真。排序真正承重见下一测试。"""
        out = _replace_ab_labels("小B 快,A 稳。", "小", "小B")
        assert out == "小B 快,小稳。"

    def test_mask_order_both_masked_prefix_pair(self):
        """双遮罩前缀对:长名先遮的排序不变量在此形态承重——短名遮壳后
        长名内露出的代号字母会被代号轮吃(实测反事实:短名先遮产出
        「小B小小B快」);现实感对(B仔/B)两种顺序结果一致,一并锁定。"""
        out = _replace_ab_labels("小B小A 快", "小B", "小B小A")
        assert out == "小B小A 快"
        out2 = _replace_ab_labels("B仔 稳,A 快。", "B仔", "B")
        assert out2 == "B仔 稳,B仔快。"

    def test_lookaround_still_protects_with_letter_names(self):
        """H1B / A4 环视保护在交叉轴名字场景下不回归。"""
        out = _replace_ab_labels("H1B 与 A4 纸，A 倾向于快。", "小B", "丽")
        assert "H1B" in out and "A4" in out
        assert "小B倾向于快" in out

    def test_latin_internal_name_letters_still_replace(self):
        """名字内字母前后是拉丁字母(如 Amy/Bella)→ 不命中 standalone,
        替换照常进行(注入的 Amy/A 内部字母非 standalone,安全)。"""
        out = _replace_ab_labels("A 倾向快,B 稳。", "Amy", "Bella")
        assert out == "Amy倾向快,Bella稳。"

    def test_latin_edge_name_adjacent_letter_protected(self):
        """无 standalone 字母的名字不做遮罩:名字首尾的拉丁字母为紧贴的
        邻接字母提供环视保护(老实现平价,差分 fuzz 实证)。「AmyB」的 B
        前邻 'y' 若被占位符换掉,B 会裸露成 standalone 被吃成「Amy丽」。"""
        out = _replace_ab_labels("AmyB 的节奏,B 稳。", "Amy", "丽")
        assert out == "AmyB 的节奏,丽稳。"

    def test_identity_names_are_noop(self):
        """老客户端兜底名即 A/B 本身(恒等替换)→ 原样返回。"""
        text = "A 与 B 的节奏"
        assert _replace_ab_labels(text, "A", "B") == text

    def test_empty_name_noop(self):
        """空名字(防御,契约上 setdefault 后不会出现)不删文本。"""
        text = "A 的节奏"
        assert _replace_ab_labels(text, "", "小林").startswith("A 的节奏")

    def test_backslash_in_name_is_literal(self):
        """名字含反斜杠(用户别名可输入)→ 替换按字面进行,不解析 re 转义
        (字符串 repl 的尾随 \\ 会抛 re.error bad escape → interpret 500;
        \\1/\\g 组引用会错插或抛错;lambda repl 返回值零转义解析,全免疫)。"""
        out = _replace_ab_labels("A 快,B 稳。", "小\\林", "小\\美")
        assert out == "小\\林快,小\\美稳。"
        # 组引用样式(\1 / \g<0>,名字不含 standalone 字母,替换照常)同样字面化
        out2 = _replace_ab_labels("A 快,B 稳。", "小\\1林", "小\\g<0>美")
        assert out2 == "小\\1林快,小\\g<0>美稳。"


class TestOffchartGanzhi:

    CONTEXT = {
        "year_a": "甲子", "month_a": "丁卯", "day_a": "甲寅", "hour_a": "庚午",
        "year_b": "己巳", "month_b": "庚午", "day_b": "丁卯", "hour_b": "辛丑",
        "synced_fortune_table": "- 2027:你「乙巳运 丁未年」→ 同步走强",
    }

    def test_offchart_char_logged(self, caplog):
        """输出提及盘外干支(申)→ warning 命中观测(真机「申位庚金」编造案)。"""
        with caplog.at_level(
            logging.WARNING, logger="app.api.interpret",
        ):
            _log_offchart_ganzhi(
                "B 的巳与 A 的申位金属庚金相映", self.CONTEXT, {})
        assert "compat_offchart_ganzhi" in caplog.text
        assert "申" in caplog.text

    def test_inchart_chars_no_warning(self, caplog):
        """只提盘中已有干支 → 不告警(甲/庚/子/水,水不在干支字符集)。"""
        with caplog.at_level(
            logging.WARNING, logger="app.api.interpret",
        ):
            _log_offchart_ganzhi(
                "甲木日主与庚金相映,子水滋养", self.CONTEXT, {})
        assert "compat_offchart_ganzhi" not in caplog.text

    def test_luck_and_annual_chars_allowed(self, caplog):
        """大运/流年干支(乙巳/丁未)在 synced 表里 → 提及不告警。"""
        with caplog.at_level(
            logging.WARNING, logger="app.api.interpret",
        ):
            _log_offchart_ganzhi(
                "乙巳运里丁未年两人同频", self.CONTEXT, {})
        assert "compat_offchart_ganzhi" not in caplog.text

    def test_name_chars_excluded_from_offchart(self, caplog):
        """两人称呼里的干支字(如「李酉」的酉)已被 _replace_ab_labels 注入
        正文,属称呼本身而非 LLM 引用 → 不计入 offchart 违约(防污染信号)。"""
        from app.api.interpret import _COMPAT_GANZHI_SOURCE_FIELDS
        context = dict(self.CONTEXT, name_a="你", name_b="李酉")
        # 前置:酉 不在任一干支来源字段(四柱=子卯寅午巳丑,synced=乙巳丁未)
        source_text = "".join(
            str(context.get(f) or "") for f in _COMPAT_GANZHI_SOURCE_FIELDS)
        assert "酉" not in source_text
        # 正文提及酉本应告警,但酉同时是名字字符 → 剔除后不再告警
        with caplog.at_level(
            logging.WARNING, logger="app.api.interpret",
        ):
            _log_offchart_ganzhi("李酉的日主与乙巳运同频", context, {})
        assert "compat_offchart_ganzhi" not in caplog.text


class TestRoutePostprocess:
    """路由级接线锁定:interpret() 内 module 成员判定 + 名字取
    translated_context + 替换先于返回(mock 应答直接进响应体)。"""

    async def test_compat_free_ab_replaced_in_response(
        self, interpret_client, mock_ai_client,
    ):
        mock_ai_client.set_response(
            "第一章 五行共振\n\nA 倾向于快,B 习惯先想清楚。")
        payload = {
            "content_hash": "compat-route-ab-001",
            "module": "compatibility_free",
            "context": {**COMPATIBILITY_CONTEXT, "name_a": "你", "name_b": "小林"},
            "target_date": None,
        }
        resp = await interpret_client.post("/api/interpret", json=payload)
        assert resp.status_code == 200, resp.json()
        body = resp.json()
        text = body["interpretation"]
        assert "你倾向于快" in text and "小林习惯先想清楚" in text
        # 正文无残留 standalone 代号
        assert "A 倾向" not in text and "B 习惯" not in text
        # 接线取的是 translated_context 名字(渲染 prompt 同源):
        # v4 header 已名字化(mock 收到的 prompt 即证明)
        assert "你（男，北京" in mock_ai_client.last_prompt
        assert "小林（女，上海" in mock_ai_client.last_prompt
        # 替换后的最终文本进缓存:同 key 二次请求命中缓存仍无代号
        resp2 = await interpret_client.post("/api/interpret", json=payload)
        assert resp2.json()["cached"] is True
        assert "A 倾向" not in resp2.json()["interpretation"]
