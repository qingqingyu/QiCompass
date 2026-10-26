"""AskGrantService 铸造编排单测(问事窗 S4b-2,2026-10-25)。

锁:钱包已有行短路(不碰 DC)/ DC bit0 已置拒发(重装防线本体)/
DC 查询失败放行(限铸闸兜底)/ DC 回写失败不回滚铸造 / 纯限铸闸降级
(client=None)/ 四种终态全覆盖。
"""

from __future__ import annotations

from app.ask.devicecheck import DeviceCheckQueryResult
from app.ask.service import AskGrantService
from app.ask.store import AskCreditsStore


class FakeDeviceCheck:
    """可编程假 DC:query_bit0 / query_success / update_ok 三个旋钮。"""

    def __init__(self, *, bit0=False, success=True, update_ok=True):
        self.bit0 = bit0
        self.success = success
        self.update_ok = update_ok
        self.query_calls = 0
        self.update_calls = 0

    def query_two_bits(self, device_token: str) -> DeviceCheckQueryResult:
        self.query_calls += 1
        return DeviceCheckQueryResult(success=self.success, bit0=self.bit0)

    def update_two_bits(self, device_token: str, *, bit0: bool) -> bool:
        self.update_calls += 1
        return self.update_ok


def _service(tmp_path, devicecheck=None) -> tuple[AskGrantService, AskCreditsStore]:
    store = AskCreditsStore(str(tmp_path / "ask.db"))
    store.init_schema()
    return AskGrantService(store, devicecheck), store


def _grant(service, *, owner="ulid:a", ip="1.2.3.4", day="2026-10-25",
           device_token=None):
    return service.grant_trial(
        owner=owner, ip=ip, day=day, credits=3, mint_limit=25,
        device_token=device_token)


class TestGrantTrial:
    def test_granted_with_bit_write(self, tmp_path):
        dc = FakeDeviceCheck()
        service, store = _service(tmp_path, dc)
        outcome = _grant(service, device_token="tok")
        assert (outcome.outcome, outcome.balance) == ("granted", 3)
        assert dc.query_calls == 1 and dc.update_calls == 1

    def test_existing_short_circuits_before_devicecheck(self, tmp_path):
        dc = FakeDeviceCheck()
        service, store = _service(tmp_path, dc)
        _grant(service, device_token="tok")
        second = _grant(service, device_token="tok")
        assert second.outcome == "existing"
        # 钱包行已存在 → DC 完全不碰
        assert dc.query_calls == 1

    def test_zero_balance_row_still_existing(self, tmp_path):
        """试用用光的老用户(余额 0 行)重进 → existing,不重发。"""
        service, store = _service(tmp_path)
        _grant(service)
        for _ in range(3):
            assert store.try_consume(owner="ulid:a")
        assert _grant(service).outcome == "existing"

    def test_device_bit_set_blocks(self, tmp_path):
        """重装防线的本体:新身份但同设备(bit0 已置)→ 拒发。"""
        dc = FakeDeviceCheck(bit0=True)
        service, store = _service(tmp_path, dc)
        outcome = _grant(service, owner="ulid:reinstall", device_token="tok")
        assert outcome.outcome == "device_blocked"
        assert store.get_balance(owner="ulid:reinstall") == 0
        assert dc.update_calls == 0  # 拒发不回写

    def test_device_query_failure_falls_back_to_mint_gate(self, tmp_path):
        """DC 故障不 500 正常用户:查询失败 → 放行铸造,限铸闸兜底。"""
        dc = FakeDeviceCheck(success=False)
        service, store = _service(tmp_path, dc)
        outcome = _grant(service, device_token="tok")
        assert outcome.outcome == "granted"

    def test_update_failure_does_not_rollback(self, tmp_path):
        """bit 回写失败不回滚铸造(最坏 = 该设备再铸一次,限铸闸封顶)。"""
        dc = FakeDeviceCheck(update_ok=False)
        service, store = _service(tmp_path, dc)
        outcome = _grant(service, device_token="tok")
        assert outcome.outcome == "granted"
        assert store.get_balance(owner="ulid:a") == 3

    def test_no_client_pure_mint_gate(self, tmp_path):
        service, store = _service(tmp_path, devicecheck=None)
        assert _grant(service, device_token="tok").outcome == "granted"

    def test_mint_limit_reached(self, tmp_path):
        service, store = _service(tmp_path)
        for i in range(25):
            assert _grant(service, owner=f"ulid:{i}", ip="9.9.9.9").outcome \
                == "granted"
        assert _grant(service, owner="ulid:x", ip="9.9.9.9").outcome \
            == "mint_limited"

    def test_device_token_absent_skips_devicecheck(self, tmp_path):
        """老客户端/DC token 获取失败不带 token → 纯限铸闸路径。"""
        dc = FakeDeviceCheck(bit0=True)
        service, store = _service(tmp_path, dc)
        assert _grant(service, device_token=None).outcome == "granted"
        assert dc.query_calls == 0
