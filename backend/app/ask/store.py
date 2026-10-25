"""问事钱包台账(ask_wallet / ask_trial_mints / ask_purchases / ask_history)。

口径(MONETIZATION.md §问事窗,2026-10-25 逐题拍板):
- 装机赠 3 次终身试用:锚 owner(user:/ulid: 前缀,对齐 interpret.py
  _paid_bucket_owner 的类型前缀纪律——两种 UUID 键空间不撞键)
- 全局钱包:不绑盘不绑日,购买 +15、每次作答 -1;不复用 per-命盘
  entitlement 行(次数包不绑 content_hash)
- 防刷 = **IP 限铸造**:每 IP 每日最多 N 个**新试用身份**(已存身份的
  调用不占 IP 名额——公共网络真实用户互不挤占,2026-10-25 拍板);
  不限调用(调用侧另有 ask-ip: 桶 300/日纯防脚本硬闸,S4b-3 接线)
- 扣减原子性(双 review 提示项):条件 UPDATE balance>=1,check-then-act
  缺口由 SQLite 单语句条件更新消除,并发不双扣不超扣
- 重复问判定(②修订版):ask_history 记 (owner,盘,日,问题哈希),
  「同用户同盘同日同题」命中 → 端点注入重复语境重生成(照扣)

实现:与 quota/store.py 同款 SQLite 短连接 + INSERT OR IGNORE + 条件
UPDATE 模式;sqlite3.Error 一律向上抛(路由层包 500,不静默放行)。
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal

_CREATE_WALLET_SQL = """
CREATE TABLE IF NOT EXISTS ask_wallet (
    owner      TEXT PRIMARY KEY,
    balance    INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);
"""

_CREATE_MINTS_SQL = """
CREATE TABLE IF NOT EXISTS ask_trial_mints (
    ip    TEXT NOT NULL,
    day   TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (ip, day)
);
"""

_CREATE_PURCHASES_SQL = """
CREATE TABLE IF NOT EXISTS ask_purchases (
    transaction_id TEXT PRIMARY KEY,
    owner          TEXT NOT NULL,
    credits        INTEGER NOT NULL,
    purchased_at   TEXT NOT NULL,
    refunded_at    TEXT
);
"""

_CREATE_HISTORY_SQL = """
CREATE TABLE IF NOT EXISTS ask_history (
    owner         TEXT NOT NULL,
    chart_hash    TEXT NOT NULL,
    day           TEXT NOT NULL,
    question_hash TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    PRIMARY KEY (owner, chart_hash, day, question_hash)
);
"""


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class TrialGrantResult:
    """try_grant_trial 的显式结果(outcome 单一事实源,调用方只认这里)。"""

    # Literal 收紧:端点按字符串分诊,typo 落 else 的静默错配在类型层挡掉
    outcome: Literal["granted", "existing", "mint_limited"]
    balance: int  # 当前余额(granted/已铸 existing 返回真实值)


class AskCreditsStore:
    """问事钱包四表(方法全部同步——路由层用 run_in_threadpool 包)。"""

    def __init__(self, db_path: str):
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表(幂等)。 Raises: sqlite3.Error(不吞)。"""
        with self._connect() as conn:
            conn.execute(_CREATE_WALLET_SQL)
            conn.execute(_CREATE_MINTS_SQL)
            conn.execute(_CREATE_PURCHASES_SQL)
            conn.execute(_CREATE_HISTORY_SQL)
            conn.commit()

    # ---------- 钱包 ----------

    def get_balance(self, *, owner: str) -> int:
        """当前余额;无行 = 0(未铸试用也未购买)。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT balance FROM ask_wallet WHERE owner = ?", (owner,)
            ).fetchone()
        return int(row[0]) if row else 0

    def wallet_row_exists(self, *, owner: str) -> bool:
        """钱包行是否存在(余额 0 的行也算——试用 3 次用光不重发)。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM ask_wallet WHERE owner = ?", (owner,)
            ).fetchone()
        return row is not None

    def try_consume(self, *, owner: str) -> bool:
        """原子扣 1 次:balance >= 1 才 UPDATE;rowcount=0 即余额不足。

        单语句条件更新,并发下不双扣不超扣(双 review 提示项的落实点)。
        """
        with self._connect() as conn:
            cursor = conn.execute(
                "UPDATE ask_wallet SET balance = balance - 1, "
                "updated_at = ? WHERE owner = ? AND balance >= 1",
                (_now_iso(), owner),
            )
            conn.commit()
            return cursor.rowcount > 0

    # ---------- 试用铸造(IP 限铸闸) ----------

    def try_grant_trial(
        self, *, owner: str, ip: str, day: str,
        credits: int, mint_limit: int,
    ) -> TrialGrantResult:
        """铸造试用:行已存在 → existing;限铸闸过 → 入账 credits。

        DeviceCheck 查询在 service 层(外部调用不进 SQLite 事务);
        本方法只管 SQLite 内的原子段:限铸计数(条件自增)与钱包入账
        (INSERT OR IGNORE)同一短事务,竞态下未入账则回退铸数,不泄漏。

        Args:
            owner: user:/ulid: 前缀身份
            ip: 归一化客户端 IP(_normalize_client_ip 同款口径,调用方传)
            day: UTC 日期串(调用方一次性算出,与计数/退款共用)
            credits: 试用次数(MONETIZATION 拍板 3)
            mint_limit: 每 IP 每日新试用铸造上限(默认 25)
        """
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT balance FROM ask_wallet WHERE owner = ?", (owner,)
            ).fetchone()
            if existing is not None:
                return TrialGrantResult("existing", int(existing[0]))

            # 限铸闸:与 free_llm_quota 同款条件自增
            conn.execute(
                "INSERT OR IGNORE INTO ask_trial_mints (ip, day, count) "
                "VALUES (?, ?, 0)", (ip, day))
            cursor = conn.execute(
                "UPDATE ask_trial_mints SET count = count + 1 "
                "WHERE ip = ? AND day = ? AND count < ?",
                (ip, day, mint_limit))
            if cursor.rowcount == 0:
                return TrialGrantResult("mint_limited", 0)

            inserted = conn.execute(
                "INSERT OR IGNORE INTO ask_wallet "
                "(owner, balance, updated_at) VALUES (?, ?, ?)",
                (owner, credits, _now_iso()))
            if inserted.rowcount == 0:
                # 竞态:并发请求同 owner 已入账——回退本次铸数,按 existing 返回
                conn.execute(
                    "UPDATE ask_trial_mints SET count = count - 1 "
                    "WHERE ip = ? AND day = ?", (ip, day))
                balance = int(conn.execute(
                    "SELECT balance FROM ask_wallet WHERE owner = ?",
                    (owner,)).fetchone()[0])
                return TrialGrantResult("existing", balance)
            conn.commit()
            return TrialGrantResult("granted", credits)

    # ---------- 购买(次数包) ----------

    def redeem_credits(
        self, *, owner: str, transaction_id: str, credits: int,
        purchased_at: str,
    ) -> bool:
        """次数包入账(幂等:transaction_id 已记录 → False 不重复加)。

        事务 = 购买留痕 + 余额自增;同一 transaction_id 二次 redeem 在
        留痕处被 PK 挡下,余额不会被加两次(防重放双入账)。
        """
        with self._connect() as conn:
            try:
                conn.execute(
                    "INSERT INTO ask_purchases "
                    "(transaction_id, owner, credits, purchased_at) "
                    "VALUES (?, ?, ?, ?)",
                    (transaction_id, owner, credits, purchased_at))
            except sqlite3.IntegrityError:
                # 撞 PK = 同 transaction_id 重放(幂等返回 False);若重查
                # 查无此单,说明 IntegrityError 另有原因(NOT NULL 等),
                # 原样上抛不吞(对齐 user_store 首登竞态的处理纪律)
                existing = conn.execute(
                    "SELECT 1 FROM ask_purchases "
                    "WHERE transaction_id = ?", (transaction_id,)).fetchone()
                if existing is None:
                    raise
                conn.rollback()
                return False
            conn.execute(
                "INSERT INTO ask_wallet (owner, balance, updated_at) "
                "VALUES (?, ?, ?) "
                "ON CONFLICT(owner) DO UPDATE SET "
                "balance = balance + excluded.balance, "
                "updated_at = excluded.updated_at",
                (owner, credits, _now_iso()))
            conn.commit()
            return True

    def refund_purchase(self, *, transaction_id: str) -> int:
        """退款扣回(下限 0):返回实际扣掉的次数(≤ credits)。

        幂等闸是原子的:先查订单,再以「refunded_at IS NULL 才置位」的
        条件 UPDATE 抢退款权——并发双退只有一方 rowcount=1,后到者在
        同一条件上得 0 直接返回(check-then-act 缺口消除,SQLite 写
        串行保证后到者看到先到者的置位)。已退/无此单 → 0,不动余额。
        余额不足 credits 时扣到 0 为止(用户已消耗的次数不追负——负余额
        会让下一次购买直接被吞,比少收回更伤正确用户)。
        """
        with self._connect() as conn:
            row = conn.execute(
                "SELECT owner, credits FROM ask_purchases "
                "WHERE transaction_id = ?", (transaction_id,)).fetchone()
            if row is None:
                return 0
            owner, credits = row
            gate = conn.execute(
                "UPDATE ask_purchases SET refunded_at = ? "
                "WHERE transaction_id = ? AND refunded_at IS NULL",
                (_now_iso(), transaction_id))
            if gate.rowcount == 0:
                return 0
            balance_row = conn.execute(
                "SELECT balance FROM ask_wallet WHERE owner = ?",
                (owner,)).fetchone()
            if balance_row is None:
                conn.commit()
                # 钱包无行(纯试用用户不可能有购买单,防御分支):
                # 留痕已置位,余额无可扣
                return 0
            deducted = min(int(balance_row[0]), credits)
            if deducted > 0:
                conn.execute(
                    "UPDATE ask_wallet SET balance = balance - ?, "
                    "updated_at = ? WHERE owner = ?",
                    (deducted, _now_iso(), owner))
            conn.commit()
            return deducted

    # ---------- 重复问判定(②修订版) ----------

    def has_asked(
        self, *, owner: str, chart_hash: str, day: str, question_hash: str,
    ) -> bool:
        """该 owner 在该盘当日是否已问过同一问题(重复语境注入依据)。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM ask_history WHERE owner = ? AND chart_hash = ? "
                "AND day = ? AND question_hash = ?",
                (owner, chart_hash, day, question_hash)).fetchone()
        return row is not None

    def record_ask(
        self, *, owner: str, chart_hash: str, day: str, question_hash: str,
    ) -> None:
        """记一次提问(INSERT OR IGNORE 幂等;PK 即判定键)。"""
        with self._connect() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO ask_history "
                "(owner, chart_hash, day, question_hash, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (owner, chart_hash, day, question_hash, _now_iso()))
            conn.commit()
