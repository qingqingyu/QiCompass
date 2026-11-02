"""ask_credits 钱包台账单测(问事窗 S4b-2,2026-10-25)。

锁:试用铸造幂等/IP 限铸/扣减原子(余额不足不放行)/购买幂等入账/
退款下限 0/重复问 history 判定——MONETIZATION.md §问事窗 技术口径的
数据层回归锚点。

并发边界说明:try_grant_trial 的竞态回退分支(INSERT OR IGNORE rowcount=0
后回退铸数)与 refund_purchase 的并发双退只有多连接交错才触发,单线程
测试不可达——原子性靠 SQL 形状本身保证(条件 UPDATE 单语句 + SQLite
写串行),不靠测试覆盖;此处的顺序用例锁的是闸门语义(条件边界/幂等)。
"""

from __future__ import annotations

import sqlite3

import pytest

from app.ask.store import AskCreditsStore


def _store(tmp_path) -> AskCreditsStore:
    store = AskCreditsStore(str(tmp_path / "ask.db"))
    store.init_schema()
    return store


def _tables(db_path: str) -> set[str]:
    with sqlite3.connect(db_path) as conn:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    return {r[0] for r in rows}


class TestSchema:
    def test_four_tables_created(self, tmp_path):
        store = _store(tmp_path)
        tables = _tables(str(tmp_path / "ask.db"))
        assert {
            "ask_wallet", "ask_trial_mints", "ask_purchases", "ask_history",
        } <= tables

    def test_init_schema_idempotent(self, tmp_path):
        store = _store(tmp_path)
        store.init_schema()  # 二次执行不抛


class TestTrialGrant:
    def test_first_grant(self, tmp_path):
        store = _store(tmp_path)
        result = store.try_grant_trial(
            owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
            credits=3, mint_limit=25)
        assert (result.outcome, result.balance) == ("granted", 3)
        assert store.get_balance(owner="ulid:a") == 3

    def test_existing_owner_no_double_grant(self, tmp_path):
        store = _store(tmp_path)
        for _ in range(2):
            store.try_grant_trial(
                owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
                credits=3, mint_limit=25)
        assert store.get_balance(owner="ulid:a") == 3
        # existing 分支不占限铸名额:同 IP 仍可给新身份铸造
        second = store.try_grant_trial(
            owner="ulid:b", ip="1.2.3.4", day="2026-10-25",
            credits=3, mint_limit=25)
        assert second.outcome == "granted"

    def test_mint_limit_blocks_new_identities(self, tmp_path):
        store = _store(tmp_path)
        for i in range(25):
            result = store.try_grant_trial(
                owner=f"ulid:{i}", ip="9.9.9.9", day="2026-10-25",
                credits=3, mint_limit=25)
            assert result.outcome == "granted"
        blocked = store.try_grant_trial(
            owner="ulid:extra", ip="9.9.9.9", day="2026-10-25",
            credits=3, mint_limit=25)
        assert blocked.outcome == "mint_limited"
        assert store.get_balance(owner="ulid:extra") == 0

    def test_mint_limit_is_per_ip_per_day(self, tmp_path):
        store = _store(tmp_path)
        for i in range(25):
            store.try_grant_trial(
                owner=f"ulid:{i}", ip="9.9.9.9", day="2026-10-25",
                credits=3, mint_limit=25)
        # 换 IP / 换日 → 独立计数,不受影响
        assert store.try_grant_trial(
            owner="ulid:otherip", ip="8.8.8.8", day="2026-10-25",
            credits=3, mint_limit=25).outcome == "granted"
        assert store.try_grant_trial(
            owner="ulid:nextday", ip="9.9.9.9", day="2026-10-26",
            credits=3, mint_limit=25).outcome == "granted"

    def test_wallet_row_exists_distinguishes_zero_balance_row(self, tmp_path):
        """余额耗尽的行仍算「铸过」——试用不因用光而重发。"""
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
            credits=3, mint_limit=25)
        for _ in range(3):
            assert store.try_consume(owner="ulid:a")
        assert store.get_balance(owner="ulid:a") == 0
        assert store.wallet_row_exists(owner="ulid:a") is True
        assert store.wallet_row_exists(owner="ulid:never") is False


class TestConsume:
    def test_consume_until_empty_then_refused(self, tmp_path):
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
            credits=2, mint_limit=25)
        assert store.try_consume(owner="ulid:a") == "trial"
        assert store.try_consume(owner="ulid:a") == "trial"
        # 原子拒绝:余额 0 后并发再扣全部失败,不出现负数
        assert store.try_consume(owner="ulid:a") is None
        assert store.get_balance(owner="ulid:a") == 0

    def test_consume_missing_wallet_refused(self, tmp_path):
        store = _store(tmp_path)
        assert store.try_consume(owner="ulid:ghost") is None


class TestRedeemAndRefund:
    def test_redeem_adds_and_is_idempotent(self, tmp_path):
        store = _store(tmp_path)
        first = store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        assert first is True
        assert store.get_balance(owner="ulid:a") == 15
        # 同 transaction_id 重放(网络重试/攻击)→ 不二次入账
        replay = store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        assert replay is False
        assert store.get_balance(owner="ulid:a") == 15

    def test_redeem_stacks_on_trial(self, tmp_path):
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
            credits=3, mint_limit=25)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        assert store.get_balance(owner="ulid:a") == 18

    def test_refund_floors_at_zero(self, tmp_path):
        """退款扣回下限 0:已消耗的次数不追负(负余额会吞掉下次购买)。"""
        store = _store(tmp_path)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        for _ in range(14):  # 消耗到剩 1
            store.try_consume(owner="ulid:a")
        assert store.get_balance(owner="ulid:a") == 1
        assert store.refund_purchase(transaction_id="txn-1") == 1
        assert store.get_balance(owner="ulid:a") == 0
        # 退款幂等:二次退不动余额
        assert store.refund_purchase(transaction_id="txn-1") == 0

    def test_refund_returns_actual_deducted(self, tmp_path):
        """返回值 = 实际扣掉的次数(余额 5 退 15 → 扣 5 返 5,非 rowcount)。"""
        store = _store(tmp_path)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        for _ in range(10):  # 消耗到剩 5
            store.try_consume(owner="ulid:a")
        assert store.get_balance(owner="ulid:a") == 5
        assert store.refund_purchase(transaction_id="txn-1") == 5
        assert store.get_balance(owner="ulid:a") == 0

    def test_refund_marks_refunded_even_without_wallet_row(self, tmp_path):
        """防御分支:留痕在但钱包行缺失 → 扣 0 返 0,且退款权已被占。"""
        store = _store(tmp_path)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        with sqlite3.connect(str(tmp_path / "ask.db")) as conn:
            conn.execute("DELETE FROM ask_wallet WHERE owner = 'ulid:a'")
            conn.commit()
        assert store.refund_purchase(transaction_id="txn-1") == 0
        # 留痕已置位:补回钱包行后二次退也不再生效(幂等闸已关)
        assert store.refund_purchase(transaction_id="txn-1") == 0

    def test_refund_unknown_transaction_zero(self, tmp_path):
        store = _store(tmp_path)
        assert store.refund_purchase(transaction_id="nope") == 0

    def test_redeem_non_pk_integrity_error_reraises(self, tmp_path):
        """IntegrityError 非撞 PK(如 NOT NULL)→ 原样上抛,不当重放吞掉。"""
        store = _store(tmp_path)
        with pytest.raises(sqlite3.IntegrityError):
            store.redeem_credits(  # type: ignore[arg-type]
                owner="ulid:a", transaction_id="txn-bad", credits=None,
                purchased_at="2026-10-25T00:00:00+00:00", environment="sandbox")
        # 未被误判为重放入账
        assert store.get_balance(owner="ulid:a") == 0


class TestAskHistory:
    def test_roundtrip_and_idempotent(self, tmp_path):
        store = _store(tmp_path)
        kwargs = dict(
            owner="ulid:a", chart_hash="chash", day="2026-10-25",
            question_hash="qhash")
        assert store.has_asked(**kwargs) is False
        store.record_ask(**kwargs)
        store.record_ask(**kwargs)  # 幂等
        assert store.has_asked(**kwargs) is True

    def test_same_question_other_day_not_repeat(self, tmp_path):
        store = _store(tmp_path)
        store.record_ask(
            owner="ulid:a", chart_hash="chash", day="2026-10-25",
            question_hash="qhash")
        assert store.has_asked(
            owner="ulid:a", chart_hash="chash", day="2026-10-26",
            question_hash="qhash") is False


class TestTrialPurchasedAttribution:
    """TASK-12(2026-11-02):试用/购买两本账——试用先扣、来源归因、
    回补退回原来源、退款只扣购买部分(口径经用户 2026-11-02 确认)。"""

    def _wallet_row(self, db_path, owner):
        with sqlite3.connect(db_path) as conn:
            return conn.execute(
                "SELECT balance, trial_balance FROM ask_wallet "
                "WHERE owner = ?", (owner,)).fetchone()

    def test_trial_consumed_first(self, tmp_path):
        """试用先扣:trial_balance 与 balance 同减,来源 "trial"。"""
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.1.1.1", day="2026-11-02",
            credits=3, mint_limit=25)
        assert store.try_consume(owner="ulid:a") == "trial"
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (2, 2)

    def test_after_trial_exhausted_charges_purchased(self, tmp_path):
        """试用扣完 → 扣购买:来源 "purchased",trial_balance 不再减。"""
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.1.1.1", day="2026-11-02",
            credits=1, mint_limit=25)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-11-02T00:00:00+00:00", environment="sandbox")
        assert store.try_consume(owner="ulid:a") == "trial"      # 试用 1
        for _ in range(3):
            assert store.try_consume(owner="ulid:a") == "purchased"
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (12, 0)

    def test_insufficient_returns_none(self, tmp_path):
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.1.1.1", day="2026-11-02",
            credits=1, mint_limit=25)
        assert store.try_consume(owner="ulid:a") == "trial"
        assert store.try_consume(owner="ulid:a") is None
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (0, 0)

    def test_concurrent_consumes_never_mislabel(self, tmp_path):
        """并发扣不错标:试用 1 + 购买 2,三线程各扣一次 →
        恰 1 个 trial + 2 个 purchased,终态 (0, 0)。SQL 形状保证原子,
        此处锁多线程交错下的语义不回归。"""
        import threading

        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.1.1.1", day="2026-11-02",
            credits=1, mint_limit=25)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=2,
            purchased_at="2026-11-02T00:00:00+00:00", environment="sandbox")
        results: list[str | None] = []
        lock = threading.Lock()

        def worker():
            r = store.try_consume(owner="ulid:a")
            with lock:
                results.append(r)

        threads = [threading.Thread(target=worker) for _ in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert sorted(r for r in results if r) == ["purchased", "purchased", "trial"]
        assert results.count(None) == 0
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (0, 0)

    def test_refund_consume_returns_to_original_source(self, tmp_path):
        """回补退回原来源:trial 扣退 trial(+trial+balance),purchased
        扣退 purchased(只 +balance);两本账不串。"""
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.1.1.1", day="2026-11-02",
            credits=1, mint_limit=25)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=1,
            purchased_at="2026-11-02T00:00:00+00:00", environment="sandbox")
        # 试用 1 扣尽 → purchased 扣 1
        assert store.try_consume(owner="ulid:a") == "trial"
        assert store.try_consume(owner="ulid:a") == "purchased"
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (0, 0)
        # 回补 purchased → 只 +balance
        assert store.refund_consume(owner="ulid:a", charged_from="purchased")
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (1, 0)
        # 回补 trial → +balance +trial
        assert store.refund_consume(owner="ulid:a", charged_from="trial")
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (2, 1)

    def test_refund_consume_rejects_unknown_source(self, tmp_path):
        store = _store(tmp_path)
        with pytest.raises(ValueError):
            store.refund_consume(owner="ulid:a", charged_from="mystery")

    def test_refund_purchase_only_deducts_purchased_part(self, tmp_path):
        """退款只扣购买部分(用户 2026-11-02 确认):试用 3 + 购买 15,
        退 15 单 → 只扣 15 购买,trial_balance 原封 3。"""
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.1.1.1", day="2026-11-02",
            credits=3, mint_limit=25)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-11-02T00:00:00+00:00", environment="sandbox")
        deducted = store.refund_purchase(transaction_id="txn-1")
        assert deducted == 15
        assert self._wallet_row(str(tmp_path / "ask.db"), "ulid:a") == (3, 3)

    def test_migration_backfills_trial_balance(self, tmp_path):
        """老表(3 列)迁移回填:无购买记录 owner → trial=balance;
        有购买记录 owner → trial=0(按已付费处理)。"""
        db = tmp_path / "ask.db"
        with sqlite3.connect(db) as conn:
            conn.execute(
                "CREATE TABLE ask_wallet ("
                "owner TEXT PRIMARY KEY, balance INTEGER NOT NULL, "
                "updated_at TEXT NOT NULL)")
            conn.execute(
                "CREATE TABLE ask_purchases ("
                "transaction_id TEXT PRIMARY KEY, owner TEXT NOT NULL, "
                "credits INTEGER NOT NULL, purchased_at TEXT NOT NULL, "
                "refunded_at TEXT)")
            conn.execute(
                "INSERT INTO ask_wallet VALUES ('ulid:pure', 3, '2026-10-25')")
            conn.execute(
                "INSERT INTO ask_wallet VALUES ('ulid:buyer', 18, '2026-10-26')")
            conn.execute(
                "INSERT INTO ask_purchases VALUES ("
                "'txn-1', 'ulid:buyer', 15, '2026-10-26', NULL)")
        store = AskCreditsStore(str(db))
        store.init_schema()
        assert self._wallet_row(str(db), "ulid:pure") == (3, 3)
        assert self._wallet_row(str(db), "ulid:buyer") == (18, 0)
