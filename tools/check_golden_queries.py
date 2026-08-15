#!/usr/bin/env python3
"""golden_queries.json 预检器 — 用 Python 精确复刻 Swift CitySearchEngine 排序,
在 XCTest 之前快速定位期望值错误 / 数据缺口(每轮省 3 分钟模拟机)。

Parent: docs/城市搜索-slices/S06
用法: python3 tools/check_golden_queries.py [--db PATH]
退出码:0 = 全过;1 = 有失败(逐条列出,便于修期望或补 curated 别名)。
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_city_db import DEFAULT_DB, normalize_key  # 同一归一化事实源


def prefers_china(nq: str) -> bool:
    return any(0x4E00 <= ord(ch) <= 0x9FFF for ch in nq)


def fetch(conn: sqlite3.Connection, key_like: str, limit: int) -> list[sqlite3.Row]:
    return conn.execute(
        """SELECT c.geoname_id, c.name, c.country_code, c.population, c.is_cn
           FROM cities c
           WHERE c.geoname_id IN (
               SELECT k.geoname_id
               FROM search_keys k JOIN cities pc ON pc.geoname_id = k.geoname_id
               WHERE k.key LIKE ?
               ORDER BY pc.population DESC, k.geoname_id ASC
               LIMIT ?
           )""",
        (key_like, limit),
    ).fetchall()


def search(conn, raw: str, limit: int = 30):
    """复刻 CitySearchEngine.search:前缀 150 → 不足补包含;排序 Q6 公式。"""
    key = normalize_key(raw)
    if not key:
        return []
    prefix = fetch(conn, key + "%", 150)
    prefix_ids = {r["geoname_id"] for r in prefix}
    ranked = [(r, 0) for r in prefix]
    if len(ranked) < limit:
        contains = [r for r in fetch(conn, "%" + key + "%", 150)
                    if r["geoname_id"] not in prefix_ids]
        ranked += [(r, 1) for r in contains]
    boost = prefers_china(key)
    def sort_key(item):
        row, mq = item
        return (mq, -row["population"], (1 if boost and not row["is_cn"] else 0), row["geoname_id"])
    ranked.sort(key=sort_key)
    return [row for row, _ in ranked[:limit]]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB,
                        help="cities.sqlite 路径(默认 iOS bundle 内产物)")
    args = parser.parse_args()
    db = args.db
    queries = json.loads((Path(__file__).parent / "city-data" / "golden_queries.json")
                         .read_text(encoding="utf-8"))
    # 空表/截断不许假绿:镜像 XCTest 的验收阈值(≥80),快速门自足
    if len(queries) < 80:
        print(f"错误: golden_queries.json 仅 {len(queries)} 条(< 80,S06 验收阈值)",
              file=sys.stderr)
        return 1
    # schema 显式校验:格式错误直接报条目位置,不落到「期望未命中」的误导诊断
    # (同时挡住 Swift 侧 $0[1] 的越界路径)
    for i, q in enumerate(queries):
        why: str | None = None
        if not isinstance(q.get("query"), str) or not q["query"]:
            why = "query 缺失或空"
        elif (not isinstance(q.get("expect"), list) or not q["expect"]
              or not all(isinstance(e, list) and len(e) == 2
                         and all(isinstance(x, str) for x in e) for e in q["expect"])):
            why = "expect 必须是非空 [[name, cc]]"
        elif not isinstance(q.get("top", 1), int) or q.get("top", 1) < 1:
            why = "top 必须是 ≥1 的整数"
        if why:
            print(f"错误: golden_queries.json 第 {i + 1} 条 「{q.get('query')}」: {why}",
                  file=sys.stderr)
            return 1
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    failures = 0
    for q in queries:
        results = search(conn, q["query"])
        top = [(r["name"], r["country_code"]) for r in results[: q.get("top", 1)]]
        missing = [e for e in map(tuple, q["expect"]) if e not in top]
        if missing:
            failures += 1
            print(f"FAIL  {q['query']!r} ({q.get('note', '')}) 期望 {q['expect']} | "
                  f"top{q.get('top', 1)} 实际 {top[:6]}")
    print(f"== {len(queries)} 条 golden queries:{len(queries) - failures} 过 / {failures} 挂 ==")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
