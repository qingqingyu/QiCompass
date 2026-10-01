#!/usr/bin/env python3
"""术语表一致性校验:backend term_translations.py ↔ iOS BaziTerms.swift(U3d,2026-09-27)。

背景(i18n-display-layer-handoff.md 决策 B):排盘响应保持中文术语作稳定 id,
iOS 建展示层三语表(BaziTerms.swift)——两边各一份术语表,有漂移风险,本脚本拦截。
对齐 check_prompt_sync.py 的既有模式(本地跑,不接 GitHub Actions)。

比对规则:
  ① 键集合 + en 值双相等(单一事实源 = backend 表,iOS 逐字复制):
     五行 / 十神 / 纳音 / 十二长生 / 神煞
  ② 仅键集合相等(en 值**有意**不同,不算漂移):
     干支 22 —— backend en = 无调拼音(进 LLM prompt),iOS en = 汉字主标
     (§3 术语显示矩阵;iOS 另有带调拼音 romanization 表,键集合须与干支并集相等)
  ③ backend ⊆ iOS(iOS 为超集,多出的是 UI 专属词汇,不算漂移):
     STRENGTH_LABEL_ZH_EN ⊆ strengthLabels(iOS 多 身强/身弱/从格/专旺 UI 词汇,
     en 值仍须与 backend 相等)
     MISC_TERMS_EN ⊆ misc;shensha.py _PILLAR_LABELS 标签 ⊆ pillarPositions
  ④ iOS 自检:跨表键冲突 / 三语字段空值 / zh ≠ 键 / en 值与 backend ① 组相等

范围外(显式记录,不算缺口):GENDER_EN / STRENGTH_LABEL_EN
(raw key)只服务后端 prompt context 翻译,iOS 展示不消费;
COMPAT_TERMS_EN 已入 ① 组(AssessmentCardGrid 展示消费);xijiMethods 值域来自
backend/app/engine/xiji.py 的代码字面量,后端无表,无法机器比对(改值时人工同步)。

用法:
    python3 tools/check_term_sync.py          # 在 repo 根执行
退出码:0 = 全部一致;1 = 有 FAIL;2 = 脚本自身错误(文件缺失等)。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"

sys.path.insert(0, str(BACKEND))

from app.engine.shensha import _PILLAR_LABELS  # noqa: E402
from app.engine.term_translations import (  # noqa: E402
    COMPAT_TERMS_EN,
    COMPAT_TERMS_ZH_HANT,
    EARTHLY_BRANCHES_EN,
    EARTHLY_BRANCHES_ZH_HANT,
    FIVE_ELEMENTS_EN,
    FIVE_ELEMENTS_ZH_HANT,
    HEAVENLY_STEMS_EN,
    HEAVENLY_STEMS_ZH_HANT,
    MISC_TERMS_EN,
    MISC_TERMS_ZH_HANT,
    NAYIN_EN,
    NAYIN_ZH_HANT,
    SHENSHA_EN,
    SHENSHA_ZH_HANT,
    STRENGTH_LABEL_ZH_EN,
    STRENGTH_LABEL_ZH_ZH_HANT,
    TEN_GODS_EN,
    TEN_GODS_ZH_HANT,
    TWELVE_STAGES_EN,
    TWELVE_STAGES_ZH_HANT,
)

# ---------- iOS 侧静态提取 ----------

SWIFT = ROOT / "ios/QiCompass/QiCompass/L10n/BaziTerms.swift"

# .init(zh: "…", zhHant: "…", en: "…") —— 允许多行书写(算法标注条目换行排)
_ENTRY = re.compile(
    r'\.init\(zh:\s*"((?:[^"\\]|\\.)*)",\s*'
    r'zhHant:\s*"((?:[^"\\]|\\.)*)",\s*'
    r'en:\s*"((?:[^"\\]|\\.)*)"\)',
    re.S,
)


def swift_table(name: str) -> dict[str, tuple[str, str]]:
    """提取 `static let <name>: [Term] = [...]` 的 {zh 键: (zhHant, en)}。"""
    text = SWIFT.read_text()
    start = f"static let {name}: [Term] = ["
    i = text.index(start)
    j = text.index("\n    ]", i)
    entries: dict[str, tuple[str, str]] = {}
    for zh, zh_hant, en in _ENTRY.findall(text[i:j]):
        if zh in entries:
            raise ValueError(f"BaziTerms.swift 表 {name} 键重复: {zh!r}")
        entries[zh] = (zh_hant, en)
    if not entries:
        raise ValueError(f"BaziTerms.swift 表 {name} 提取为空(书写格式变了?)")
    return entries


def swift_romanization_keys() -> set[str]:
    text = SWIFT.read_text()
    start = "static let romanization: [String: String] = ["
    i = text.index(start)
    j = text.index("\n    ]", i)
    return set(re.findall(r'"([^"]+)"\s*:', text[i:j]))


# ---------- 主流程 ----------

def main() -> int:
    failures: list[str] = []
    warnings: list[str] = []

    ios_tables = {
        name: swift_table(name)
        for name in ("heavenlyStems", "earthlyBranches", "fiveElements", "tenGods",
                     "misc", "shensha", "nayin", "twelveStages", "strengthLabels",
                     "pillarPositions", "xijiMethods", "compatTerms")
    }

    print("=" * 64)
    print("① 键集合 + en/zh-hant 值三相等(backend 为单一事实源)")
    print("=" * 64)
    # 每组给 (en 表, zh-hant 表, iOS 表名);zh-hant 值也须与 iOS zhHant 列
    # 逐字相等(S2,backend zh-hant 表从 iOS 定稿转写,此后双向锁定)
    exact = {
        "五行": (FIVE_ELEMENTS_EN, FIVE_ELEMENTS_ZH_HANT, "fiveElements"),
        "十神": (TEN_GODS_EN, TEN_GODS_ZH_HANT, "tenGods"),
        "纳音": (NAYIN_EN, NAYIN_ZH_HANT, "nayin"),
        "十二长生": (TWELVE_STAGES_EN, TWELVE_STAGES_ZH_HANT, "twelveStages"),
        "神煞": (SHENSHA_EN, SHENSHA_ZH_HANT, "shensha"),
        "合盘枚举": (COMPAT_TERMS_EN, COMPAT_TERMS_ZH_HANT, "compatTerms"),
    }
    for label, (backend_table, backend_hant, ios_name) in exact.items():
        ios = ios_tables[ios_name]
        b_keys, i_keys = set(backend_table), set(ios)
        label_out = f"  {label:<6} {ios_name:<14}"
        if b_keys != i_keys:
            failures.append(
                f"表 {ios_name} 键集合漂移: 仅backend={sorted(b_keys - i_keys)} "
                f"仅iOS={sorted(i_keys - b_keys)}"
            )
            print(f"{label_out} FAIL 键集合漂移")
            continue
        value_drift = [
            k for k in backend_table
            if ios[k][1] != backend_table[k] or ios[k][0] != backend_hant[k]
        ]
        if value_drift:
            failures.append(
                f"表 {ios_name} en/zh-hant 值漂移: "
                + "; ".join(
                    f"{k}: backend en={backend_table[k]!r} hant={backend_hant[k]!r}"
                    f" iOS en={ios[k][1]!r} hant={ios[k][0]!r}"
                    for k in value_drift[:5])
            )
            print(f"{label_out} FAIL en/zh-hant 值漂移 {len(value_drift)} 条")
        else:
            print(f"{label_out} OK   {len(b_keys)} 条键值全等")

    print("=" * 64)
    print("② 仅键集合相等(en 值有意不同:backend 拼音进 prompt / iOS 汉字主标)")
    print("=" * 64)
    ganzi_backend = {**HEAVENLY_STEMS_EN, **EARTHLY_BRANCHES_EN}
    ganzi_ios = {**ios_tables["heavenlyStems"], **ios_tables["earthlyBranches"]}
    if set(ganzi_backend) != set(ganzi_ios):
        failures.append(
            f"干支键集合漂移: 仅backend={sorted(set(ganzi_backend) - set(ganzi_ios))} "
            f"仅iOS={sorted(set(ganzi_ios) - set(ganzi_backend))}"
        )
        print("  干支    FAIL 键集合漂移")
    else:
        print(f"  干支    OK   {len(ganzi_backend)} 键全命中")
    roman_keys = swift_romanization_keys()
    if roman_keys != set(ganzi_backend):
        failures.append(
            f"romanization 表键集合 ≠ 干支并集: 仅表={sorted(roman_keys - set(ganzi_backend))} "
            f"仅干支={sorted(set(ganzi_backend) - roman_keys)}"
        )
        print("  转写    FAIL romanization 键 ≠ 干支并集")
    else:
        print("  转写    OK   romanization 键集合 = 干支并集")

    print("=" * 64)
    print("③ backend ⊆ iOS(iOS 超集 = UI 专属词汇,en/zh-hant 值仍须相等)")
    print("=" * 64)
    subsets = [
        ("旺衰", STRENGTH_LABEL_ZH_EN, STRENGTH_LABEL_ZH_ZH_HANT, "strengthLabels"),
        ("杂项", MISC_TERMS_EN, MISC_TERMS_ZH_HANT, "misc"),
        ("柱位", {label: None for _attr, label in _PILLAR_LABELS}, None, "pillarPositions"),
    ]
    for label, backend_table, backend_hant, ios_name in subsets:
        ios = ios_tables[ios_name]
        missing = set(backend_table) - set(ios)
        out = f"  {label:<6} {ios_name:<14}"
        if missing:
            failures.append(f"表 {ios_name} 缺 backend 注册键: {sorted(missing)}")
            print(f"{out} FAIL 缺 {sorted(missing)}")
            continue
        # 柱位的 backend 值是 attr 名(位置标记,非译名),只比键集合;
        # 旺衰/杂项的 backend en/zh-hant 是译名,值也须相等
        if backend_hant is None:
            value_drift = []
        else:
            value_drift = [
                k for k in backend_table
                if backend_table[k] and (
                    ios[k][1] != backend_table[k]
                    or ios[k][0] != backend_hant[k])
            ]
        if value_drift:
            failures.append(
                f"表 {ios_name} en 值漂移: "
                + "; ".join(f"{k}: backend={backend_table[k]!r} iOS={ios[k][1]!r}"
                            for k in value_drift[:5])
            )
            print(f"{out} FAIL en 值漂移 {len(value_drift)} 条")
        else:
            extra = set(ios) - set(backend_table)
            note = f"(iOS 超集 +{len(extra)} UI 词条)" if extra else ""
            print(f"{out} OK   {len(backend_table)} 条全命中 {note}")

    print("=" * 64)
    print("④ iOS 自检(跨表冲突 / 空值 / zh≠键)")
    print("=" * 64)
    seen: dict[str, str] = {}
    collision = False
    for name, table in ios_tables.items():
        for zh, (zh_hant, en) in table.items():
            if not zh_hant or not en:
                failures.append(f"表 {name} 条目 {zh!r} 三语字段有空值")
            if zh in seen and seen[zh] != name:
                failures.append(f"跨表键冲突: {zh!r} 同时在 {seen[zh]} 与 {name}")
                collision = True
            seen[zh] = name
    if not collision:
        print(f"  全部 {sum(len(t) for t in ios_tables.values())} 条 / "
              f"{len(ios_tables)} 表无冲突,无空值"
              + ("" if not [f for f in failures if "空值" in f] else " —— 见上方 FAIL"))

    print("=" * 64)
    if failures:
        print(f"结果: FAIL({len(failures)} 项)")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print(f"结果: PASS(warning {len(warnings)} 项)")
    print("范围外(显式记录):GENDER/STRENGTH_LABEL_EN(raw key)只服务后端"
          " prompt context 翻译;xijiMethods 后端无表(值域在 xiji.py 代码字面量,人工同步)。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FileNotFoundError, ValueError) as e:
        print(f"脚本自身错误(文件缺失/标记找不到): {e}", file=sys.stderr)
        sys.exit(2)
