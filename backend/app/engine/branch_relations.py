"""地支关系常量(单一事实源,合盘引擎 + onboarding 生肖关系共用)。

从 compatibility.py 抽出,降低 god class 行数(510 → ~470)。
2026-08-13 onboarding 三屏重构:反馈屏「好朋友/需磨合」复用本模块六合/三合/六冲表。
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

# 地支顺序(子→亥),排序展示用(三合组内两友按此序稳定输出)
ZHI_ORDER: dict[str, int] = {
    z: i for i, z in enumerate("子丑寅卯辰巳午未申酉戌亥")
}


def _pair_with(pairs: frozenset[frozenset[str]], zhi: str) -> str:
    """在二支关系表(六合/六冲)中找 zhi 的配对地支。缺失 → ValueError。"""
    for pair in pairs:
        if zhi in pair:
            return next(iter(pair - {zhi}))
    raise ValueError(f"二支关系中缺失地支: {zhi!r}")


def compute_friends_and_clash(year_zhi: str) -> tuple[list[str], str]:
    """年柱地支 → (好朋友地支 list, 需磨合地支)。

    2026-08-13 onboarding 三屏重构:反馈屏「好朋友 / 需磨合」。
    - 好朋友 = 六合 1 支(排第一)+ 三合 2 支(按地支顺序),共 3 支
    - 需磨合 = 六冲 1 支
    未知地支 → ValueError(错误显式传播,不静默吞)。
    """
    if year_zhi not in ZHI_ORDER:
        raise ValueError(f"未知地支: {year_zhi!r}")

    liuhe = _pair_with(LIUHE, year_zhi)
    sanhe_group = next((g for g in SANHE if year_zhi in g), None)
    if sanhe_group is None:
        raise ValueError(f"三合局缺失地支: {year_zhi!r}")
    # 用 __getitem__ 而非 .get:若关系表与 ZHI_ORDER 不同步,KeyError 显式失败
    # (.get 会返回 None 导致 sorted 抛隐蔽 TypeError)
    sanhe_two = sorted(
        (z for z in sanhe_group if z != year_zhi), key=ZHI_ORDER.__getitem__,
    )
    clash = _pair_with(LIUCHONG, year_zhi)
    return [liuhe, *sanhe_two], clash
