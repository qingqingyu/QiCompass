#!/usr/bin/env python3
"""GeoNames cities500 → promo 城市 SQLite(2026-08-15)。

数据源: https://download.geonames.org/export/dump/cities500.zip
(全球人口>500 聚落,~23.5 万行;中国 1.6 万,镇级乡级全覆盖)
许可: GeoNames 数据 CC-BY 4.0(内部工具,注明来源即可)。

用法(数据更新时重复跑):
    cd tmp/promo-site/tools
    curl -fsSL -o /tmp/cities500.zip https://download.geonames.org/export/dump/cities500.zip
    unzip -o -q /tmp/cities500.zip -d /tmp
    python3 build_city_db.py /tmp/cities500.txt

产物: tmp/promo-site/data/cities.db(README 记录大小;tmp/ 整体 gitignore,不进 git)。

设计:
- 中文名来自第 4 列 alternatenames(逗号分隔)里含 CJK 的项,多个中文别名都拆成
  独立行(name_zh 不唯一,搜索命中率高);无中文别名的行只留拼音/英文名。
- population 排序用(搜索时优先大城);country/admin1 供下拉展示。
- 无新依赖:sqlite3 是 stdlib。
"""

from __future__ import annotations

import re
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "cities.db"

# GeoNames cities500.txt 列序(tab 分隔,19 列)
# 0 geonameid, 1 name, 2 asciiname, 3 alternatenames, 4 lat, 5 lng,
# 6 feature class, 7 feature code, 8 country code, 9 cc2, 10 admin1,
# 11 admin2, 12 admin3, 13 admin4, 14 population, 15 elevation,
# 16 dem, 17 timezone, 18 modification date
_CJK = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")


def zh_names(alternatenames: str) -> list[str]:
    """alternatenames 列 → 中文别名列表(去重,保持顺序)。"""
    seen: list[str] = []
    for part in alternatenames.split(","):
        part = part.strip()
        if part and _CJK.search(part):
            if part not in seen:
                seen.append(part)
    return seen


def build(txt_path: Path) -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    conn = sqlite3.connect(DB_PATH)
    # rowid 表 + 索引(不用 PK 抑制重复:搜索场景重复无害;且 name_zh 可为 NULL,
    # WITHOUT ROWID + OR IGNORE 会把 NULL 主键行静默吞掉——2026-08-15 踩过,
    # 16.8 万无中文别名的城全丢,违反"错误显式传播",此处注释留档)
    conn.executescript("""
        CREATE TABLE cities (
            geonameid INTEGER NOT NULL,
            name_zh   TEXT,
            name      TEXT NOT NULL,   -- GeoNames 主名(拼音/英文)
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            country  TEXT NOT NULL,
            admin1   TEXT,
            population INTEGER NOT NULL DEFAULT 0,
            tz       TEXT NOT NULL     -- IANA 时区名
        );
        CREATE INDEX idx_name_zh ON cities(name_zh);
        CREATE INDEX idx_name ON cities(name);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    rows: list[tuple] = []
    lines_read = 0
    bad_lines = 0
    with txt_path.open(encoding="utf-8") as f:
        for line in f:
            lines_read += 1
            c = line.rstrip("\n").split("\t")
            if len(c) < 18:
                bad_lines += 1
                continue
            gid, name, alt, lat, lng = c[0], c[1], c[3], c[4], c[5]
            country, admin1 = c[8], c[10] if len(c) > 10 else ""
            population = int(c[14]) if c[14].strip().isdigit() else 0
            tz = c[17]
            zh = zh_names(alt)
            if zh:
                for z in zh:
                    rows.append((int(gid), z, name, float(lat), float(lng),
                                 country, admin1, population, tz))
            else:
                rows.append((int(gid), None, name, float(lat), float(lng),
                             country, admin1, population, tz))
    if bad_lines:
        raise ValueError(f"cities500 有 {bad_lines}/{lines_read} 行列数不足 18,数据格式变化,需人工检查")
    if len(rows) < lines_read:
        raise ValueError(
            f"行数守卫失败:源 {lines_read} 行只产出 {len(rows)} 条记录,存在静默丢失")
    conn.executemany(
        "INSERT INTO cities VALUES (?,?,?,?,?,?,?,?,?)", rows)
    conn.execute("INSERT INTO meta VALUES ('source','GeoNames cities500, CC-BY 4.0')")
    conn.commit()
    n = conn.execute("SELECT COUNT(*) FROM cities").fetchone()[0]
    n_zh = conn.execute(
        "SELECT COUNT(*) FROM cities WHERE name_zh IS NOT NULL").fetchone()[0]
    conn.close()
    size_mb = DB_PATH.stat().st_size / 1024 / 1024
    print(f"OK {DB_PATH} : {n} 行(含中文别名 {n_zh}),{size_mb:.1f}MB")


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/cities500.txt")
    if not src.exists():
        print(f"数据文件不存在: {src}(先下载 cities500.zip 并解压,见文件头注释)",
              file=sys.stderr)
        sys.exit(2)
    build(src)
