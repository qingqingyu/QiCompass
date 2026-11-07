"""地支关系常量(单一事实源,合盘引擎 + onboarding 生肖关系共用)。

从 compatibility.py 抽出,降低 god class 行数(510 → ~470)。
2026-08-13 onboarding 三屏重构:反馈屏「好朋友/需磨合」复用本模块六合/三合/六冲表。
2026-11-07 借鉴项②:三会表归一进本模块(原只在 shensha.py),新增单盘
四柱地支关系分析 analyze_natal_branch_relations(v1 deep chart 注入用)。
"""

from __future__ import annotations

from .pillars import EN2ZH  # 英文五行 → 中文(单向:pillars 不依赖本模块)

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

# ---------- 三会方(4 组, 每组 3 支): 亥子丑 / 寅卯辰 / 巳午未 / 申酉戌 ----------
# (2026-11-07 自 shensha.py 归一为正典;shensha 侧自此派生)

SANHUI: tuple[frozenset[str], ...] = (
    frozenset({"亥", "子", "丑"}),
    frozenset({"寅", "卯", "辰"}),
    frozenset({"巳", "午", "未"}),
    frozenset({"申", "酉", "戌"}),
)

# 传统组名序(申子辰/亥子丑…非地支序);shensha 组名/成员序与展示形态依赖
SANHE_TRIPLES: tuple[tuple[str, str, str], ...] = (
    ("申", "子", "辰"), ("寅", "午", "戌"), ("巳", "酉", "丑"), ("亥", "卯", "未"),
)
SANHUI_TRIPLES: tuple[tuple[str, str, str], ...] = (
    ("亥", "子", "丑"), ("寅", "卯", "辰"), ("巳", "午", "未"), ("申", "酉", "戌"),
)
# 组 → 五行(英文 key,对齐 GAN_ELEMENT 口径;中文化在分析器内做)
SANHE_ELEMENT: dict[frozenset[str], str] = {
    frozenset(g): elem for g, elem in zip(
        SANHE_TRIPLES, ("water", "fire", "metal", "wood"))
}
SANHUI_ELEMENT: dict[frozenset[str], str] = {
    frozenset(g): elem for g, elem in zip(
        SANHUI_TRIPLES, ("water", "wood", "fire", "metal"))
}
# frozenset 匹配表与组名序表同步守卫(两处手写,不同步即启动报错)
assert frozenset(frozenset(g) for g in SANHE_TRIPLES) == frozenset(SANHE), (
    "SANHE 与 SANHE_TRIPLES 不同步(engine/branch_relations.py)")
assert frozenset(frozenset(g) for g in SANHUI_TRIPLES) == frozenset(SANHUI), (
    "SANHUI 与 SANHUI_TRIPLES 不同步(engine/branch_relations.py)")

# 自刑支(同支重复见于四柱时成自刑;经典四支)
ZIXING: frozenset[str] = frozenset({"辰", "午", "酉", "亥"})



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

# ---------- 单盘四柱地支关系分析(2026-11-07 借鉴项②)----------

# 柱位序(年→月→日→时;与 chart pillars 键一致,稳定输出用)
_PILLAR_ORDER: tuple[str, ...] = ("year", "month", "day", "hour")

# 成化声明(chart branch_relations.note;三语注册见 term_translations)
_BRANCH_RELATIONS_NOTE = "四柱地支客观关系;成化与否未判定"


def analyze_natal_branch_relations(pillars: dict) -> dict | None:
    """单盘四柱地支关系清单(v1 deep chart 注入数据,确定性纯函数)。

    输入 chart pillars 形状 {year: {"zhi": …}|None, …}。pillar 缺失/非
    dict/zhi 非地支 → 该柱跳过(未验签 chart 的脏数据交 token 验签拒绝,
    本函数不是安全边界;时辰未知盘 hour 缺失属常态)。

    清单口径(docs/prompt对比-徐子平skill-20261107.md 借鉴项②拍板):
    - pairs:柱两两单标签,优先序 六合→六冲→相害→相刑(仅子卯);
      同支重复且属自刑支(辰午酉亥)→ 自刑条目
    - groups:三合局/三会方按表序查全 3/3,附五行;element 在本函数内
      转中文;三刑只列全组(寅巳申/丑戌未),无五行
    - 层级双录:寅巳 pair 记相害,寅巳申全时组层另记三刑(不同层事实
      并存,对齐徐子平先例;合盘判定序 v2 是汇总标签竞争序,与此不冲突)
    - 不含半合;成化一律不判定(note 声明)

    Returns:
        {"pairs": […], "groups": […], "note": …};无任何有效地支 → None。
        确定性:同输入同输出(对齐 CLAUDE.md 八字计算确定性约束)。
    """
    entries: list[tuple[str, str]] = []  # (柱位键, 地支),按柱位序
    for key in _PILLAR_ORDER:
        pillar = pillars.get(key) if isinstance(pillars, dict) else None
        if not isinstance(pillar, dict):
            continue
        zhi = pillar.get("zhi")
        if isinstance(zhi, str) and zhi in ZHI_ORDER:
            entries.append((key, zhi))
    if not entries:
        return None

    pairs: list[dict] = []
    for i in range(len(entries)):
        for j in range(i + 1, len(entries)):
            key_a, zhi_a = entries[i]
            key_b, zhi_b = entries[j]
            pair = frozenset((zhi_a, zhi_b))
            if zhi_a == zhi_b:
                rel = "自刑" if zhi_a in ZIXING else None
            elif pair in LIUHE:
                rel = "六合"
            elif pair in LIUCHONG:
                rel = "六冲"
            elif pair in XIANGHAI:
                rel = "相害"
            elif pair == SANXING[2]:  # 子卯(三刑表唯一二支组,对级单记)
                rel = "相刑"
            else:
                rel = None
            if rel is not None:
                pairs.append({
                    "pillars": [key_a, key_b],
                    "branches": [zhi_a, zhi_b],
                    "type": rel,
                })

    # 地支 → 柱位列表(柱位序;组层每支取首个出现柱位)
    positions: dict[str, list[str]] = {}
    for key, zhi in entries:
        positions.setdefault(zhi, []).append(key)

    def _group_entry(group: frozenset[str], rel: str,
                     elements: dict[frozenset[str], str] | None) -> dict | None:
        """全 3/3 命中 → 组条目(柱位=各支首现柱位按柱位序;地支按地支序)。"""
        if not all(z in positions for z in group):
            return None
        return {
            "pillars": sorted(
                (positions[z][0] for z in group), key=_PILLAR_ORDER.index),
            "branches": sorted(group, key=ZHI_ORDER.__getitem__),
            "type": rel,
            **({"element": EN2ZH[elements[group]]} if elements else {}),
        }

    groups: list[dict] = []
    for sanhe in SANHE:
        entry = _group_entry(sanhe, "三合", SANHE_ELEMENT)
        if entry is not None:
            groups.append(entry)
    for sanhui in SANHUI:
        entry = _group_entry(sanhui, "三会", SANHUI_ELEMENT)
        if entry is not None:
            groups.append(entry)
    for xing in (SANXING[0], SANXING[1]):  # 全组三刑(寅巳申/丑戌未)
        entry = _group_entry(xing, "三刑", None)
        if entry is not None:
            groups.append(entry)

    return {"pairs": pairs, "groups": groups, "note": _BRANCH_RELATIONS_NOTE}
