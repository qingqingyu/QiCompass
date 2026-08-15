"""城市数据库守护栏(CI 侧轻量校验)。

Parent: docs/城市搜索-slices/S01 — backend pytest 挂一条轻量用例:
cities.sqlite 存在 + manifest hash 一致。结构/抽查的完整校验在
tools/check_city_db.py(动了 build 脚本 / sqlite / 别名表时必跑)。
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DB_PATH = REPO_ROOT / "ios" / "QiCompass" / "QiCompass" / "Resources" / "cities.sqlite"
MANIFEST_PATH = REPO_ROOT / "tools" / "city-data" / "manifest.json"


def test_city_db_exists() -> None:
    assert DB_PATH.exists(), (
        f"缺少 {DB_PATH} — 先跑 python3 tools/build_city_db.py(guard: docs/城市搜索-slices/S01)"
    )


def test_city_db_manifest_hash_matches() -> None:
    assert MANIFEST_PATH.exists(), f"缺少 {MANIFEST_PATH}"
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    sha = hashlib.sha256(DB_PATH.read_bytes()).hexdigest()
    assert sha == manifest["sqlite_sha256"], (
        "cities.sqlite 与 manifest.json 的 sha256 不一致 — "
        "重跑 tools/build_city_db.py(改 build 脚本/别名表后必须重跑并跑 check_city_db.py)"
    )
