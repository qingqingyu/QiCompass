"""xiji v2 扶抑打分标定 spike(2026-11-07 借鉴项④,Phase 2 真人闸门输入)。

用法(backend/ 下):
    arch -arm64 .venv/bin/python -m spikes.xiji_v2_calibration

产出:spikes/xiji_v2_calibration_report.md——
1. 50 盘 fixtures(45 普通 + 5 特殊)+ evalkit 20 盘,v2 公式实跑
2. 对照 fixtures 钉死的 v1 结论(= v1 公式实跑输出,非手算),列翻转明细
3. 阈值网格扫描(STRONG×WEAK):按「翻转最少 + 分布不畸变」给推荐候选
4. special_pattern 5 盘核验(检测逻辑 v2 未动,应全部不翻)

权重=徐子平基线(拍板 2026-11-07);阈值由本报告交用户抽样问真核对后拍板。
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_ROOT))

from evalkit.cases import CASES  # noqa: E402
from tests.fixtures.xiji_cases import XIJI_CASES  # noqa: E402

from app.engine.bazi_engine import BaziEngine  # noqa: E402
from app.engine.pillars import compute_element_balance  # noqa: E402
from app.engine.pillars import GAN_ELEMENT, SHENG_WO  # noqa: E402
from app.engine.xiji import (  # noqa: E402
    GAN_PEER_FACTOR,
    GAN_POSITION_FACTOR,
    GAN_RESOURCE_FACTOR,
    MONTH_TENGOD_WEIGHTS,
    ROOT_WEIGHTS,
    STRONG_THRESHOLD,
    WEAK_THRESHOLD,
)
from app.models.bazi import Pillar, Pillars  # noqa: E402

FIXED_NOW = datetime(2026, 7, 12, 12, 0, tzinfo=timezone(timedelta(hours=8)))

# 阈值扫描网格(拍板前占位 4.5/1.5 也在候选内)
STRONG_GRID = [round(3.5 + 0.25 * i, 2) for i in range(15)]   # 3.5 .. 7.0
WEAK_GRID = [round(0.0 + 0.25 * i, 2) for i in range(13)]     # 0.0 .. 3.0


def _run_case(birth_str: str, gender: str, longitude: float,
              zi_hour_rule: str) -> dict:
    """跑引擎拿 snapshot(真太阳时全链),返回标定所需明细。"""
    birth = datetime.fromisoformat(birth_str)
    engine = BaziEngine(now=FIXED_NOW)
    result = engine.calculate(
        birth=birth, gender=gender,
        longitude=longitude, zi_hour_rule=zi_hour_rule,
    )
    pillars = Pillars(**{
        k: (Pillar(**v) if isinstance(v, dict) else None)
        for k, v in result["pillars"].items()})
    day_element = GAN_ELEMENT[pillars.day.gan]

    # 分数构成明细(与 xiji._compute_fuyi_score v2 同口径重演,仅为报告)
    month_god = pillars.month.shishen_zhi[0]
    parts = [f"月令{month_god}{MONTH_TENGOD_WEIGHTS[month_god]:+.2f}"]
    score = MONTH_TENGOD_WEIGHTS[month_god]
    for label, pillar in (("年", pillars.year), ("月", pillars.month),
                          ("日", pillars.day), ("时", pillars.hour)):
        for idx, gan in enumerate(pillar.hide_gan):
            if GAN_ELEMENT[gan] == day_element:
                w = ROOT_WEIGHTS[idx] if idx < len(ROOT_WEIGHTS) else ROOT_WEIGHTS[-1]
                score += w
                parts.append(f"根·{label}{pillar.zhi}{gan}({['本', '中', '余'][min(idx, 2)]}){w:+.2f}")
                break
    for key, label, pillar in (("year", "年", pillars.year),
                               ("month", "月", pillars.month),
                               ("hour", "时", pillars.hour)):
        ge = GAN_ELEMENT[pillar.gan]
        if ge == day_element:
            w = GAN_POSITION_FACTOR[key] * GAN_PEER_FACTOR
            score += w
            parts.append(f"干·{label}{pillar.gan}(比){w:+.2f}")
        elif ge == SHENG_WO[day_element]:
            w = GAN_POSITION_FACTOR[key] * GAN_RESOURCE_FACTOR
            score += w
            parts.append(f"干·{label}{pillar.gan}(印){w:+.2f}")
    return {
        "pillars_gz": " ".join(
            p.gan_zhi if p else "??"
            for p in (pillars.year, pillars.month, pillars.day, pillars.hour)),
        "strength_engine": result["day_master_strength"],
        "score_v2": score,
        "parts": parts,
    }


def _classify(score: float, strong: float, weak: float) -> str:
    if score >= strong:
        return "strong"
    if score <= weak:
        return "weak"
    return "balanced"


def main() -> None:
    lines: list[str] = []
    lines.append("# xiji v2 扶抑打分标定报告(借鉴项④)\n")
    lines.append(f"- 生成:spikes/xiji_v2_calibration.py · 引擎规则 v2"
                 f" · FIXED_NOW={FIXED_NOW.isoformat()}")
    lines.append("- 对照基线:tests/fixtures/xiji_cases.py 钉死的 v1 结论"
                 "(45 普通 + 5 特殊)+ evalkit/cases.py 20 盘\n")

    # ---------- 跑全量 ----------
    rows: list[dict] = []
    for case in XIJI_CASES:
        info = _run_case(
            case["birth_datetime"], case["gender"],
            case["longitude"], case["zi_hour_rule"])
        info["label"] = case["birth_datetime"] + " " + case["gender"]
        info["v1"] = case["expected"]["strength"]
        rows.append(info)

    evalkit_rows: list[dict] = []
    for case in CASES:
        info = _run_case(
            case["birth_datetime"], case["gender"],
            case["longitude"], case["zi_hour_rule"])
        info["label"] = case["birth_datetime"] + " " + case["gender"]
        info["v1"] = case["expected_strength"]
        evalkit_rows.append(info)

    normal = [r for r in rows if r["v1"] != "special_pattern"]
    special = [r for r in rows if r["v1"] == "special_pattern"]

    # ---------- special 核验(检测逻辑未动) ----------
    bad_special = [r for r in special if r["strength_engine"] != "special_pattern"]
    lines.append("## special_pattern 核验(5 盘,检测逻辑 v2 未动)\n")
    lines.append("- 全部保持 special_pattern ✓" if not bad_special
                 else f"- ⚠️ 翻盘 {len(bad_special)} 例:"
                      + "; ".join(r["label"] for r in bad_special))
    lines.append("")

    # ---------- 阈值扫描 ----------
    lines.append("## 阈值扫描(45 普通盘,v2 分数 × 网格,对照 v1 结论)\n")
    lines.append("| STRONG≥ | WEAK≤ | 翻转 | 分布 s/b/w |")
    lines.append("|---|---|---|---|")
    candidates = []
    for s in STRONG_GRID:
        for w in WEAK_GRID:
            if s - w < 1.5:  # balanced 带宽至少 1.5,防退化为二值
                continue
            flips = sum(
                1 for r in normal
                if _classify(r["score_v2"], s, w) != r["v1"])
            dist = {"strong": 0, "balanced": 0, "weak": 0}
            for r in normal:
                dist[_classify(r["score_v2"], s, w)] += 1
            candidates.append((flips, abs(dist["strong"] - 22)
                               + abs(dist["balanced"] - 9)
                               + abs(dist["weak"] - 14), s, w, dist))
    candidates.sort(key=lambda t: (t[0], t[1]))
    for flips, _, s, w, dist in candidates[:12]:
        lines.append(f"| {s} | {w} | {flips} | "
                     f"{dist['strong']}/{dist['balanced']}/{dist['weak']} |")
    best = candidates[0]
    lines.append("")
    lines.append(f"**推荐初值**:STRONG≥{best[2]},WEAK≤{best[3]}"
                 f"(翻转 {best[0]}/45,分布 "
                 f"{best[4]['strong']}/{best[4]['balanced']}/{best[4]['weak']}"
                 f" vs v1 的 22/9/14)\n")

    # ---------- 翻转明细(推荐阈值) ----------
    flips = [r for r in normal
             if _classify(r["score_v2"], best[2], best[3]) != r["v1"]]
    lines.append(f"## 翻转明细({len(flips)} 盘,推荐阈值下)\n")
    lines.append("| 盘 | 四柱 | v1 | v2 | score | 构成 |")
    lines.append("|---|---|---|---|---|---|")
    for r in sorted(flips, key=lambda x: x["label"]):
        lines.append(
            f"| {r['label']} | {r['pillars_gz']} | {r['v1']} | "
            f"{_classify(r['score_v2'], best[2], best[3])} | "
            f"{r['score_v2']:.2f} | {'; '.join(r['parts'])} |")
    lines.append("")

    # ---------- evalkit 20 盘对照 ----------
    lines.append("## evalkit 20 盘(引擎 v2 实测 vs cases.py 钉值)\n")
    lines.append("| 盘 | v1(钉) | v2(引擎) | score |")
    lines.append("|---|---|---|---|")
    ek_flips = 0
    for r in evalkit_rows:
        mark = ""
        if r["strength_engine"] != r["v1"]:
            ek_flips += 1
            mark = " ←翻转"
        lines.append(f"| {r['label']} | {r['v1']} | "
                     f"{r['strength_engine']}{mark} | {r['score_v2']:.2f} |")
    lines.append(f"\nevalkit 翻转 {ek_flips}/20;cases.py 的 expected_strength"
                 " 须在阈值拍板后同步重钉(CASES_HASH 变=新 run 身份,设计内)。"
                 "special_pattern 盘引擎实际 score=-1(未计算),表中 score 为"
                 "标定脚本假设走的扶抑分数,仅参考。\n")
    lines.append(f"## 现行占位阈值({STRONG_THRESHOLD}/{WEAK_THRESHOLD})对照\n")
    cur_flips = sum(1 for r in normal
                    if _classify(r["score_v2"], STRONG_THRESHOLD,
                                 WEAK_THRESHOLD) != r["v1"])
    cur_dist = {"strong": 0, "balanced": 0, "weak": 0}
    for r in normal:
        cur_dist[_classify(r["score_v2"], STRONG_THRESHOLD,
                           WEAK_THRESHOLD)] += 1
    lines.append(f"- 翻转 {cur_flips}/45,分布 "
                 f"{cur_dist['strong']}/{cur_dist['balanced']}/{cur_dist['weak']}"
                 "\n")

    report = "\n".join(lines)
    out = BACKEND_ROOT / "spikes" / "xiji_v2_calibration_report.md"
    out.write_text(report, encoding="utf-8")
    print(report)
    print(f"\n[written] {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
