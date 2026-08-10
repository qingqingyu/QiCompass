"""UserChartSync 表 SQLite Store(PR3.1)。

表结构:
- PK = id(服务端 UUID)
- UNIQUE(user_id, content_hash):同用户同命盘去重(content_hash 内容寻址)
- 包含 ChartSnapshot + UserSnapshotLink 合并字段(同步时一次往返)

策略(对齐 plan):
- 全量同步(不做 lastSyncAt 增量,v2 用户命盘少)
- 冲突解决 last-write-wins(updated_at 最新覆盖)
- UPSERT:INSERT OR REPLACE 或显式 SELECT+UPDATE

错误显式传播(对齐 entitlement/store.py + user_store.py):sqlite3 异常不吞。
"""

from __future__ import annotations

import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

# 建表语句(幂等,lifespan 启动时执行)
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS user_chart_sync (
    id                  TEXT PRIMARY KEY,
    user_id             TEXT NOT NULL,
    content_hash        TEXT NOT NULL,
    alias               TEXT NOT NULL,
    schema_version      INTEGER NOT NULL,
    birth_solar_time    TEXT NOT NULL,
    gender              TEXT NOT NULL,
    city_longitude      REAL NOT NULL,
    zi_hour_rule        TEXT NOT NULL,
    calc_rule_snapshot  TEXT NOT NULL,
    payload             TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    UNIQUE(user_id, content_hash)
);
"""

CREATE_INDEX_USER_SQL = """
CREATE INDEX IF NOT EXISTS idx_user_chart_sync_user
ON user_chart_sync(user_id);
"""


@dataclass(frozen=True)
class UserChartSync:
    """user_chart_sync 行(只读)。"""

    id: str
    user_id: str
    content_hash: str
    alias: str
    schema_version: int
    birth_solar_time: str
    gender: str
    city_longitude: float
    zi_hour_rule: str
    calc_rule_snapshot: str  # Base64
    payload: str  # JSON 字符串
    created_at: str
    updated_at: str


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class UserChartSyncStore:
    """user_chart_sync 表 CRUD(对齐 entitlement/store.py + user_store.py 模式)。"""

    def __init__(self, db_path: str):
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self._db_path, timeout=5.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    def init_schema(self) -> None:
        """lifespan 启动时调用,幂等建表。"""
        with self._connect() as conn:
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_INDEX_USER_SQL)

    def upsert(
        self,
        *,
        user_id: str,
        content_hash: str,
        alias: str,
        schema_version: int,
        birth_solar_time: str,
        gender: str,
        city_longitude: float,
        zi_hour_rule: str,
        calc_rule_snapshot: str,
        payload: str,
        created_at: str,
    ) -> UserChartSync:
        """按 (user_id, content_hash) upsert。

        - 不存在 → 插入新行(id 服务端 UUID,updated_at = now)
        - 已存在 → 更新所有字段(包括 alias / payload),updated_at = now
          created_at 保持原值(客户端首次创建时间)

        Returns:
            UserChartSync(upsert 后的最终状态)
        """
        now = _now_iso()
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT * FROM user_chart_sync WHERE user_id=? AND content_hash=?",
                (user_id, content_hash),
            ).fetchone()

            if existing is None:
                new_id = str(uuid.uuid4())
                conn.execute(
                    """INSERT INTO user_chart_sync
                       (id, user_id, content_hash, alias, schema_version,
                        birth_solar_time, gender, city_longitude, zi_hour_rule,
                        calc_rule_snapshot, payload, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (new_id, user_id, content_hash, alias, schema_version,
                     birth_solar_time, gender, city_longitude, zi_hour_rule,
                     calc_rule_snapshot, payload, created_at, now),
                )
                return UserChartSync(
                    id=new_id, user_id=user_id, content_hash=content_hash,
                    alias=alias, schema_version=schema_version,
                    birth_solar_time=birth_solar_time, gender=gender,
                    city_longitude=city_longitude, zi_hour_rule=zi_hour_rule,
                    calc_rule_snapshot=calc_rule_snapshot, payload=payload,
                    created_at=created_at, updated_at=now,
                )
            else:
                # 保留 created_at(客户端首次创建时间),更新其他字段 + updated_at
                conn.execute(
                    """UPDATE user_chart_sync SET
                         alias=?, schema_version=?, birth_solar_time=?,
                         gender=?, city_longitude=?, zi_hour_rule=?,
                         calc_rule_snapshot=?, payload=?, updated_at=?
                       WHERE user_id=? AND content_hash=?""",
                    (alias, schema_version, birth_solar_time,
                     gender, city_longitude, zi_hour_rule,
                     calc_rule_snapshot, payload, now,
                     user_id, content_hash),
                )
                return UserChartSync(
                    id=existing["id"], user_id=user_id, content_hash=content_hash,
                    alias=alias, schema_version=schema_version,
                    birth_solar_time=birth_solar_time, gender=gender,
                    city_longitude=city_longitude, zi_hour_rule=zi_hour_rule,
                    calc_rule_snapshot=calc_rule_snapshot, payload=payload,
                    created_at=existing["created_at"], updated_at=now,
                )

    def list_by_user(self, user_id: str) -> list[UserChartSync]:
        """按 user_id 查所有命盘(created_at ASC)。"""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM user_chart_sync WHERE user_id=? "
                "ORDER BY created_at ASC",
                (user_id,),
            ).fetchall()
        return [
            UserChartSync(
                id=r["id"], user_id=r["user_id"], content_hash=r["content_hash"],
                alias=r["alias"], schema_version=r["schema_version"],
                birth_solar_time=r["birth_solar_time"], gender=r["gender"],
                city_longitude=r["city_longitude"], zi_hour_rule=r["zi_hour_rule"],
                calc_rule_snapshot=r["calc_rule_snapshot"], payload=r["payload"],
                created_at=r["created_at"], updated_at=r["updated_at"],
            )
            for r in rows
        ]

    def count_by_user(self, user_id: str) -> int:
        """统计 user 命盘数量(/api/sync/push 响应用)。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) AS cnt FROM user_chart_sync WHERE user_id=?",
                (user_id,),
            ).fetchone()
        return int(row["cnt"])
