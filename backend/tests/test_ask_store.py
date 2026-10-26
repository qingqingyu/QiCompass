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
        assert store.try_consume(owner="ulid:a") is True
        assert store.try_consume(owner="ulid:a") is True
        # 原子拒绝:余额 0 后并发再扣全部失败,不出现负数
        assert store.try_consume(owner="ulid:a") is False
        assert store.get_balance(owner="ulid:a") == 0

    def test_consume_missing_wallet_refused(self, tmp_path):
        store = _store(tmp_path)
        assert store.try_consume(owner="ulid:ghost") is False


class TestRedeemAndRefund:
    def test_redeem_adds_and_is_idempotent(self, tmp_path):
        store = _store(tmp_path)
        first = store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00")
        assert first is True
        assert store.get_balance(owner="ulid:a") == 15
        # 同 transaction_id 重放(网络重试/攻击)→ 不二次入账
        replay = store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00")
        assert replay is False
        assert store.get_balance(owner="ulid:a") == 15

    def test_redeem_stacks_on_trial(self, tmp_path):
        store = _store(tmp_path)
        store.try_grant_trial(
            owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
            credits=3, mint_limit=25)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00")
        assert store.get_balance(owner="ulid:a") == 18

    def test_refund_floors_at_zero(self, tmp_path):
        """退款扣回下限 0:已消耗的次数不追负(负余额会吞掉下次购买)。"""
        store = _store(tmp_path)
        store.redeem_credits(
            owner="ulid:a", transaction_id="txn-1", credits=15,
            purchased_at="2026-10-25T00:00:00+00:00")
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
            purchased_at="2026-10-25T00:00:00+00:00")
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
            purchased_at="2026-10-25T00:00:00+00:00")
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
                purchased_at="2026-10-25T00:00:00+00:00")
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
