#!/usr/bin/env python3
"""城市数据库守护栏校验 — 结构 / manifest hash / 关键城市抽查。

Parent: docs/城市搜索设计决策.md Q9;Slice: docs/城市搜索-slices/S01
触发规则:动了 tools/build_city_db.py / curated_aliases.tsv / cities.sqlite 之后,
必须跑本脚本且 PASS 才算完成。

退出码:0 = PASS;1 = FAIL(任一断言失败,逐条列出)。
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_city_db as b  # 复用常量与归一化,防两份实现漂移

DB_PATH = b.DEFAULT_DB
MANIFEST_PATH = b.MANIFEST_PATH

EXPECTED_COLUMNS = {
    "cities": {"geoname_id", "name", "name_zh", "name_en", "country_code",
               "admin1_code", "admin1_name", "lat", "lon", "tz_id", "is_cn", "population"},
    "timezones": {"tz_id", "iana_name"},
    "countries": {"country_code", "name_zh", "name_en"},
    "search_keys": {"key", "geoname_id", "key_type"},
}

# 关键城市抽查:(GeoNames name, country, 期望 tz, 期望经度±0.05°)
SPOT_CITIES = [
    ("Beijing", "CN", "Asia/Shanghai", 116.4074),
    ("Los Angeles", "US", "America/Los_Angeles", -118.2437),
    ("London", "GB", "Europe/London", -0.1276),
    ("Sydney", "AU", "Australia/Sydney", 151.2073),
    ("Tokyo", "JP", "Asia/Tokyo", 139.6917),
]

# 县级市 / 海外小城覆盖抽查:(name_zh 模糊匹配)
SPOT_NAME_ZH_CONTAINS = ["昆山", "义乌", "连云港", "Berkeley", "Corvallis", "Schenectady"]

# 海外同名城消歧抽查(S01 验收:Cambridge 英/美两条都在)
SPOT_DUP_NAME = [("Cambridge", {"GB", "US"})]

# 搜索键行为抽查:(查询输入, 期望命中的 name, 国家码)
SPOT_QUERIES = [
    ("乌鲁", "Ürümqi", "CN"),          # 简体前缀(乌鲁木齐首两字)
    ("wulumuqi", "Ürümqi", "CN"),       # 全拼
    ("wlmq", "Ürümqi", "CN"),           # 拼音首字母
    ("xian", "Xi’an", "CN"),            # 分隔符归一(Xi’an U+2019 → xian)
    ("三藩市", "San Francisco", "US"),  # curated 别名
    ("海淀", "Beijing", "CN"),          # curated 区县别名
    ("汉口", "Wuhan", "CN"),            # curated 历史地名
    ("臺北", "Taipei", "TW"),           # 繁体
    ("munchen", "Munich", "DE"),        # 变音符折叠 + curated
    ("changshu", "Changshu", "CN"),     # curated 中文显示名兜底(拼音键)
    ("常熟", "Changshu", "CN"),         # curated 中文显示名兜底(汉字键)
]


def main() -> int:
    errors: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if cond:
            print(f"  ok  {msg}")
        else:
            errors.append(msg)
            print(f"FAIL  {msg}")

    if not DB_PATH.exists():
        print(f"FAIL  缺少 {DB_PATH}(先跑 tools/build_city_db.py)")
        return 1
    if not MANIFEST_PATH.exists():
        print(f"FAIL  缺少 {MANIFEST_PATH}")
        return 1

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    print("== 1/5 表结构 ==")
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    cur = conn.cursor()
    for table, expected in EXPECTED_COLUMNS.items():
        cols = {r[1] for r in cur.execute(f"PRAGMA table_info({table})")}
        check(cols == expected, f"{table} 列集合一致({len(expected)} 列)")

    print("== 2/5 manifest hash / 计数 ==")
    sha = hashlib.sha256(DB_PATH.read_bytes()).hexdigest()
    check(sha == manifest["sqlite_sha256"], "sqlite sha256 与 manifest 一致")
    check(manifest["schema_version"] == b.SCHEMA_VERSION, "schema_version 一致")
    n_cities = cur.execute("SELECT COUNT(*) FROM cities").fetchone()[0]
    n_keys = cur.execute("SELECT COUNT(*) FROM search_keys").fetchone()[0]
    n_tz = cur.execute("SELECT COUNT(*) FROM timezones").fetchone()[0]
    n_cc = cur.execute("SELECT COUNT(*) FROM countries").fetchone()[0]
    check(n_cities == manifest["cities"], f"cities 计数 = {n_cities} 与 manifest 一致")
    check(n_keys == manifest["search_keys"], f"search_keys 计数 = {n_keys} 与 manifest 一致")
    check(n_tz == manifest["timezones"], f"timezones 计数 = {n_tz} 与 manifest 一致")
    check(n_cc == manifest["countries"], f"countries 计数 = {n_cc} 与 manifest 一致")

    print("== 3/5 关键城市坐标/时区 ==")
    for name, cc, tz, lon in SPOT_CITIES:
        row = cur.execute(
            """SELECT c.geoname_id, t.iana_name, c.lon, c.population, c.name_zh
               FROM cities c JOIN timezones t ON t.tz_id = c.tz_id
               WHERE c.name = ? AND c.country_code = ?""", (name, cc)).fetchone()
        if row is None:
            check(False, f"{name} ({cc}) 在库中")
            continue
        gid, tz_actual, lon_scaled, pop, name_zh = row
        lon_actual = lon_scaled / 10000
        check(tz_actual == tz, f"{name} tz = {tz_actual}(期望 {tz})")
        check(abs(lon_actual - lon) <= 0.05, f"{name} lon = {lon_actual:.4f}(期望 {lon} ±0.05)")
    pop_bj = cur.execute(
        "SELECT population FROM cities WHERE name='Beijing' AND country_code='CN'").fetchone()
    check(pop_bj is not None and pop_bj[0] > 5_000_000, "北京人口 > 500 万(数据质量)")

    print("== 4/5 中文名 / 县级市覆盖 ==")
    for frag in SPOT_NAME_ZH_CONTAINS:
        n = cur.execute(
            "SELECT COUNT(*) FROM cities WHERE name_zh LIKE ? OR name LIKE ?",
            (f"%{frag}%", f"%{frag}%")).fetchone()[0]
        check(n > 0, f"「{frag}」可查({n} 条)")
    for name, expect_ccs in SPOT_DUP_NAME:
        got_ccs = {r[0] for r in cur.execute(
            "SELECT DISTINCT country_code FROM cities WHERE name = ?", (name,))}
        check(expect_ccs <= got_ccs,
              f"「{name}」英/美同名城都在(实际国家 {sorted(got_ccs)})")

    print("== 5/5 搜索键行为(用真实 LIKE 查询)==")
    for query, expect_name, expect_cc in SPOT_QUERIES:
        nk = b.normalize_key(query)
        rows = cur.execute(
            """SELECT c.name, c.country_code FROM search_keys k
               JOIN cities c ON c.geoname_id = k.geoname_id
               WHERE k.key LIKE ? ESCAPE '\\'
               ORDER BY c.population DESC LIMIT 8""",
            (nk + "%",)).fetchall()
        hit = any(r == (expect_name, expect_cc) for r in rows)
        top = rows[0] if rows else None
        check(hit, f"「{query}」→ {expect_name} 出现在前 8(首位:{top})")

    conn.close()

    if errors:
        print(f"\n== FAIL:{len(errors)} 项不过 ==")
        return 1
    print("\n== PASS:结构 / hash / 抽查全绿 ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
