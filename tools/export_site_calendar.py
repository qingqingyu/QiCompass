#!/usr/bin/env python3
"""官网日历数据导出器(S04 首页「今日条」+ Library 六十甲子格)。

产出 site/src/data/calendar.json:
- days: 自构建日(UTC+8)起 400 天,每天锚定 12:00 +08:00 取四柱年月日干支、
  阴历月日、当前节气与下一节气(含精确日期)。
- jiazi: 六十甲子全表(序号 / 干支 / 元素着色 / 罗马化 / 纳音),纳音以 lunar_python
  查表、术语名以 site/src/data/terms.json 为准(不一致 = 构建期抛错)。

硬约束:
- **确定性**:同一构建日重跑 byte-identical(不写时间戳,只写 buildDay);
- **强制 setSect(1)**(23:00 换日,与产品全局决策一致,禁用库默认 sect=2);
- **fail-loud**:自检断言不过、纳音键不在 terms.json、当日不在窗口内,
  一律非零退出,绝不静默产出缺数据站点(README §12「今日条 build 期生成,fail-loud」)。

用法(必须用 backend venv,worktree 借主仓):
  arch -arm64 /Users/TWJ/工作/git/QiCompass/backend/.venv/bin/python \
    tools/export_site_calendar.py [--days 400] [--build-day YYYY-MM-DD]

build-day 仅用于测试;默认取 UTC+8 当天。CI/发布构建必须走默认。
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from lunar_python import Solar

REPO = Path(__file__).resolve().parent.parent
SITE_DATA = REPO / "site" / "src" / "data"
TERMS_JSON = SITE_DATA / "terms.json"
OUT_JSON = SITE_DATA / "calendar.json"

TZ_CN = ZoneInfo("Asia/Shanghai")

# 二十四节气:唯一中文名 → 标准英文名(设计稿 home.html 今日条同款译名)。
JIEQI_EN = {
    "立春": "Beginning of Spring", "雨水": "Rain Water",
    "惊蛰": "Awakening of Insects", "春分": "Spring Equinox",
    "清明": "Pure Brightness", "谷雨": "Grain Rain",
    "立夏": "Beginning of Summer", "小满": "Grain Buds",
    "芒种": "Grain in Ear", "夏至": "Summer Solstice",
    "小暑": "Minor Heat", "大暑": "Major Heat",
    "立秋": "Beginning of Autumn", "处暑": "End of Heat",
    "白露": "White Dew", "秋分": "Autumn Equinox",
    "寒露": "Cold Dew", "霜降": "Frost's Descent",
    "立冬": "Beginning of Winter", "小雪": "Minor Snow",
    "大雪": "Major Snow", "冬至": "Winter Solstice",
    "小寒": "Minor Cold", "大寒": "Major Cold",
}

# 天干 / 地支 → 五行(传统定数,着色用;与 terms.json fiveElements 键同名)。
STEM_ELEMENT = {
    "甲": "wood", "乙": "wood", "丙": "fire", "丁": "fire",
    "戊": "earth", "己": "earth", "庚": "metal", "辛": "metal",
    "壬": "water", "癸": "water",
}
BRANCH_ELEMENT = {
    "寅": "wood", "卯": "wood", "巳": "fire", "午": "fire",
    "辰": "earth", "戌": "earth", "丑": "earth", "未": "earth",
    "申": "metal", "酉": "metal", "亥": "water", "子": "water",
}


def fail(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"[export_site_calendar] FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def eight_char_for(y: int, m: int, d: int, hh: int = 12, mm: int = 0):
    """取某时刻(按 +08:00 语义输入)的四柱;强制 setSect(1)。"""
    ec = Solar.fromYmdHms(y, m, d, hh, mm, 0).getLunar().getEightChar()
    ec.setSect(1)  # 23:00 换日,禁用库默认 sect=2 早晚子时
    return ec


# lunar_python 节气表的拼音键 = 农历年头尾跨界节气(与同名正中文键相差一年,
# 都是真实时刻,不是重复);映射回中文名后与正名键合并成全年序列。
PINYIN_JIEQI = {
    "DA_XUE": "大雪", "DONG_ZHI": "冬至", "XIAO_HAN": "小寒",
    "DA_HAN": "大寒", "LI_CHUN": "立春", "YU_SHUI": "雨水",
    "JING_ZHE": "惊蛰",
}


def jieqi_span(target: Solar) -> list[tuple[datetime, str]]:
    """收集 target 所属农历年表的全部节气(24 正名 + 7 跨界拼音键),按时刻排序。

    合并后共 31 个真实时刻,覆盖全年任何锚点的「当前 + 下一个」;出现表外
    未知键 = 库版本漂移,fail-loud。
    """
    out: list[tuple[datetime, str]] = []
    for name, moment in target.getLunar().getJieQiTable().items():
        resolved = name if name in JIEQI_EN else PINYIN_JIEQI.get(name)
        if resolved is None or resolved not in JIEQI_EN:
            fail(f"节气表出现未知条目 {name!r},请复核 lunar_python 版本")
        naive = moment.toYmdHms()  # Solar 时刻,按 +08:00 语义
        dt = datetime.strptime(naive, "%Y-%m-%d %H:%M:%S").replace(tzinfo=TZ_CN)
        out.append((dt, resolved))
    out.sort(key=lambda x: x[0])
    if len(out) != 31:
        fail(f"节气条目数 {len(out)} != 31(target {target.toYmd()})")
    return out


def load_terms() -> dict:
    if not TERMS_JSON.exists():
        fail(f"terms.json 不存在: {TERMS_JSON}(先跑 tools/export_site_terms.py)")
    return json.loads(TERMS_JSON.read_text(encoding="utf-8"))


def build_days(build_day: date, n_days: int) -> list[dict]:
    days: list[dict] = []
    for offset in range(n_days):
        d = build_day + timedelta(days=offset)
        anchor = datetime(d.year, d.month, d.day, 12, 0, tzinfo=TZ_CN)
        ec = eight_char_for(d.year, d.month, d.day)
        lunar = Solar.fromYmdHms(d.year, d.month, d.day, 12, 0, 0).getLunar()
        span = jieqi_span(Solar.fromYmdHms(d.year, d.month, d.day, 12, 0, 0))
        cur = [x for x in span if x[0] <= anchor]
        nxt = [x for x in span if x[0] > anchor]
        if not cur or not nxt:
            fail(f"{d} 节气窗口不覆盖锚点(当前 {len(cur)} / 下个 {len(nxt)})")
        days.append({
            "date": d.isoformat(),
            "y": ec.getYear(), "m": ec.getMonth(), "d": ec.getDay(),
            "lunarM": lunar.getMonth(),  # 负数 = 闰月
            "lunarD": lunar.getDay(),
            "jieqi": cur[-1][1],
            "jieqiEn": JIEQI_EN[cur[-1][1]],
            "nextJieqi": nxt[0][1],
            "nextJieqiEn": JIEQI_EN[nxt[0][1]],
            "nextDate": nxt[0][0].date().isoformat(),
        })
    return days


def build_jiazi(terms: dict) -> list[dict]:
    from lunar_python.util.LunarUtil import LunarUtil

    stems = terms["groups"]["heavenlyStems"]
    branches = terms["groups"]["earthlyBranches"]
    nayin_terms = terms["groups"]["nayin"]

    rows: list[dict] = []
    for i in range(60):
        stem = list(stems.keys())[i % 10]
        branch = list(branches.keys())[i % 12]
        gz = stem + branch
        for ch, table, group in ((stem, STEM_ELEMENT, stems), (branch, BRANCH_ELEMENT, branches)):
            if ch not in table or ch not in group:
                fail(f"{gz} 字 {ch} 不在元素映射或 terms.json 中")
        ny = LunarUtil.NAYIN.get(gz)
        if ny is None:
            fail(f"{gz} 库中无纳音")
        if ny not in nayin_terms:
            fail(f"纳音 {ny}({gz}) 不在 terms.json nayin 组——术语表与库漂移,禁止静默继续")
        ny_row = nayin_terms[ny]
        if "en" not in ny_row or "zhHant" not in ny_row:
            fail(f"纳音 {ny}({gz}) 缺 en/zhHant 译名——先修 terms.json")
        en = f"{stems[stem]['en']} {branches[branch]['en']}"
        rows.append({
            "i": i + 1, "gz": gz, "en": en,
            "elS": STEM_ELEMENT[stem], "elB": BRANCH_ELEMENT[branch],
            "nayin": ny, "nayinEn": ny_row["en"], "nayinHant": ny_row["zhHant"],
        })
    return rows


def self_test(days: list[dict], jiazi: list[dict]) -> None:
    # 1. 对盘锚点:2026-11-24 = 丙午 / 己亥 / 壬寅,阴历十月十六,节气小雪
    nov24 = next((x for x in days if x["date"] == "2026-11-24"), None)
    if nov24 is not None:
        ok = (nov24["y"], nov24["m"], nov24["d"]) == ("丙午", "己亥", "壬寅") \
            and nov24["lunarM"] == 10 and nov24["lunarD"] == 16 \
            and nov24["jieqi"] == "小雪" and nov24["nextJieqi"] == "大雪" \
            and nov24["nextDate"] == "2026-12-07"
        if not ok:
            fail(f"2026-11-24 对盘不过: {nov24}")
    # 2. 设计稿样例盘:1992-04-18 12:00 日柱 = 甲子
    ec = eight_char_for(1992, 4, 18)
    if ec.getDay() != "甲子":
        fail(f"1992-04-18 日柱 {ec.getDay()} != 甲子")
    # 3. sect=1 语义:23:30 属次日日柱(锚定 12:00 时含混性被排除)
    late = eight_char_for(2026, 11, 24, 23, 30)
    next_day = eight_char_for(2026, 11, 25, 12, 0)
    if late.getDay() != next_day.getDay():
        fail(f"23:30 未换日: {late.getDay()} != {next_day.getDay()}")
    # 4. 六十甲子首尾与元素映射完整
    if jiazi[0]["gz"] != "甲子" or jiazi[-1]["gz"] != "癸亥":
        fail(f"六十甲子首尾异常: {jiazi[0]['gz']} / {jiazi[-1]['gz']}")
    # 5. 日期连续无缺口
    for a, b in zip(days, days[1:]):
        if date.fromisoformat(b["date"]) - date.fromisoformat(a["date"]) != timedelta(days=1):
            fail(f"日期断档: {a['date']} → {b['date']}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=400)
    ap.add_argument("--build-day", type=str, default=None, help="仅测试用;默认 UTC+8 当天")
    args = ap.parse_args()

    if args.build_day:
        build_day = date.fromisoformat(args.build_day)
    else:
        build_day = datetime.now(TZ_CN).date()

    terms = load_terms()
    days = build_days(build_day, args.days)
    jiazi = build_jiazi(terms)
    self_test(days, jiazi)

    today = next((x for x in days if x["date"] == build_day.isoformat()), None)
    if today is None:
        fail(f"构建日 {build_day} 不在产出窗口内")

    payload = {
        "buildDay": build_day.isoformat(),
        "days": days,
        "jiazi": jiazi,
    }
    OUT_JSON.write_text(
        json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"[export_site_calendar] OK: {len(days)} 天 → {OUT_JSON} (buildDay={build_day})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
