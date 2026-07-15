"""地支关系常量(单一事实源,合盘引擎专用)。

从 compatibility.py 抽出,降低 god class 行数(510 → ~470)。
"""

from __future__ import annotations

# 六合(6 对): 子丑 / 寅亥 / 卯戌 / 辰酉 / 巳申 / 午未
LIUHE: frozenset[frozenset[str]] = frozenset({
    frozenset({"子", "丑"}), frozenset({"寅", "亥"}),
    frozenset({"卯", "戌"}), frozenset({"辰", "酉"}),
    frozenset({"巳", "申"}), frozenset({"午", "未"}),
})

# 三合局(4 组, 每组 3 支): 申子辰 / 寅午戌 / 巳酉丑 / 亥卯未
SANHE: tuple[frozenset[str], ...] = (
    frozenset({"申", "子", "辰"}),
    frozenset({"寅", "午", "戌"}),
    frozenset({"巳", "酉", "丑"}),
    frozenset({"亥", "卯", "未"}),
)

# 六冲(6 对): 子午 / 丑未 / 寅申 / 卯酉 / 辰戌 / 巳亥
LIUCHONG: frozenset[frozenset[str]] = frozenset({
    frozenset({"子", "午"}), frozenset({"丑", "未"}),
    frozenset({"寅", "申"}), frozenset({"卯", "酉"}),
    frozenset({"辰", "戌"}), frozenset({"巳", "亥"}),
})

# 三刑(经典组合): 寅巳申 / 丑戌未 / 子卯
SANXING: tuple[frozenset[str], ...] = (
    frozenset({"寅", "巳", "申"}),
    frozenset({"丑", "戌", "未"}),
    frozenset({"子", "卯"}),
)

# 相害(6 对): 子未 / 丑午 / 寅巳 / 卯辰 / 申亥 / 酉戌
XIANGHAI: frozenset[frozenset[str]] = frozenset({
    frozenset({"子", "未"}), frozenset({"丑", "午"}),
    frozenset({"寅", "巳"}), frozenset({"卯", "辰"}),
    frozenset({"申", "亥"}), frozenset({"酉", "戌"}),
})
