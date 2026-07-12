"""/api/interpret 测试用例 fixtures。

三 module 各一个完整 context(基于 1990-03-15 14:30 北京 男 命盘构造),
数值不求与真实排盘完全一致,但求字段齐全、类型正确,用于测试 prompt 渲染与缓存行为。
"""

from __future__ import annotations

# 1990-03-15 14:30 北京 男 → 庚午年 己卯月 己卯日 辛未时(日主己土 weak)
BAZI_DEEP_CONTEXT = {
    "gender": "男",
    "city": "北京",
    "true_solar_time": "1990-03-15 14:30:00 (真太阳时偏移 +0.0 分钟)",
    # 年柱 庚午
    "year_gan": "庚",
    "year_zhi": "午",
    "year_gan_element": "金",
    "year_zhi_element": "火",
    "year_shishen_gan": "伤官",
    "year_hide_gan": "丁,己",
    # 月柱 己卯
    "month_gan": "己",
    "month_zhi": "卯",
    "month_gan_element": "土",
    "month_zhi_element": "木",
    "month_shishen_gan": "比肩",
    "month_hide_gan": "乙",
    # 日柱 己卯(日主 己)
    "day_gan": "己",
    "day_zhi": "卯",
    "day_gan_element": "土",
    "day_shishen_zhi": '["正官"]',
    "day_hide_gan": "乙",
    # 时柱 辛未
    "hour_gan": "辛",
    "hour_zhi": "未",
    "hour_gan_element": "金",
    "hour_zhi_element": "土",
    "hour_shishen_gan": "食神",
    "hour_hide_gan": "己,丁,乙",
    # 纳音
    "year_nayin": "路旁土",
    "month_nayin": "城头土",
    "day_nayin": "城头土",
    "hour_nayin": "路旁土",
    # 命宫
    "ming_gong": "壬辰",
    "ming_gong_nayin": "长流水",
    # 神煞 + 五行
    "shensha_list": "天乙贵人(日柱), 文昌(日柱), 桃花(年柱)",
    "element_balance": "木2 火1 土2 金2 水0 (总计8)",
    # 喜忌(普通盘)
    "day_master_strength": "weak",
    "favorable_elements": "火, 土",
    "unfavorable_elements": "水, 金",
    "tiaoshou_applied": False,
    "current_luck_pillar": "庚辰 (30-39岁)",
    "current_year_pillar": "丙午 (2026)",
}

# 从格版(触发诚实降级)
BAZI_DEEP_SPECIAL_PATTERN_CONTEXT = {
    **BAZI_DEEP_CONTEXT,
    "day_master_strength": "special_pattern",
    "favorable_elements": "",
    "unfavorable_elements": "",
    "tiaoshou_applied": False,
}

# 合盘 context(合成数据,A/B 两盘)
COMPATIBILITY_CONTEXT = {
    "context_label": "婚姻",
    "gender_a": "男",
    "city_a": "北京",
    "birth_a": "1990-03-15 14:30",
    "day_master_a": "己土",
    "day_master_strength_a": "weak",
    "favorable_a": "火,土",
    "year_a": "庚午",
    "month_a": "己卯",
    "day_a": "己卯",
    "hour_a": "辛未",
    "element_balance_a": "木2 火1 土2 金2 水0",
    "gender_b": "女",
    "city_b": "上海",
    "birth_b": "1992-08-20 10:00",
    "day_master_b": "庚金",
    "day_master_strength_b": "strong",
    "favorable_b": "水,木",
    "year_b": "壬申",
    "month_b": "戊申",
    "day_b": "庚子",
    "hour_b": "辛巳",
    "element_balance_b": "木0 火0 土1 金3 水4",
    "five_elements_assessment": "互补佳(A 缺火水,B 金水旺)",
    "day_master_relation": "土生金(A 日主生 B 日主)",
    "zodiac_match": "午申(半三合)",
    "branch_harmony": "卯未半合(月时)",
    "synced_fortune_table": "2026: A 入火运/B 入水运 | 2027: 同步好转 | 2028: A 平稳/B 波动",
}

# 每日运势 context
DAILY_FORTUNE_CONTEXT = {
    "day_master": "己",
    "day_master_element": "土",
    "day_master_strength": "weak",
    "favorable_elements": "火,土",
    "unfavorable_elements": "水,金",
    "date": "2026-07-12",
    "lunar_date": "五月廿八",
    "day_pillar": "甲申",
    "day_stem": "甲",
    "day_stem_element": "木",
    "day_branch": "申",
    "day_branch_element": "金",
    "day_relation": "偏官日",
    "day_chong": "寅",
    "hour_pillars_with_relations": (
        "子(23-1): 甲子 正官 冲午 | 丑(1-3): 乙丑 偏官 | "
        "寅(3-5): 丙寅 正印 冲申 | ..."
    ),
    "huangli_yi": "嫁娶, 祭祀, 祈福",
    "huangli_ji": "赴任, 出行",
}
