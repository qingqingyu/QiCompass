"""问事试用铸造编排(ask.service)——DeviceCheck × 限铸闸 × 钱包串联。

流程(MONETIZATION.md §问事窗,S4b-2):
1. 钱包已有行 → EXISTING(已铸过/已购过,零副作用直返)
2. DeviceCheck 启用且带 device_token → query bit0:
   - bit0=True → DEVICE_BLOCKED(该物理设备已铸过,重装不再发)
   - 查询失败 → 放行(限铸闸兜底;exception 日志在 client 内)
3. store.try_grant_trial(IP 限铸 → 原子入账 3 次)
4. 铸造成功且 DC 启用 → update bit0=True(失败不回滚,见 devicecheck 注释)

调用方(S4b-3 端点)只认 GrantOutcome,四种终态全覆盖,无隐式分支。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Literal

from .devicecheck import DeviceCheckClient
from .store import AskCreditsStore, TrialGrantResult

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class GrantOutcome:
    """铸造终态(balance 为当前余额;blocked/limited 时为查询值或 0)。"""

    # Literal 收紧:S4b-3 端点按 outcome 字符串分诊,typo 在类型层挡掉
    outcome: Literal[
        "granted", "existing", "device_blocked", "mint_limited"]
    balance: int


class AskGrantService:
    """铸造编排:store(必需)+ devicecheck(可缺 = 纯限铸闸降级)。"""

    def __init__(
        self, store: AskCreditsStore,
        devicecheck: DeviceCheckClient | None = None,
    ):
        self._store = store
        self._devicecheck = devicecheck

    def grant_trial(
        self, *, owner: str, ip: str, day: str,
        credits: int, mint_limit: int,
        device_token: str | None = None,
    ) -> GrantOutcome:
        # 1. 已有钱包行(已铸过或已购过,余额 0 也算)→ 直返,不碰 DC/限铸
        if self._store.wallet_row_exists(owner=owner):
            balance = self._store.get_balance(owner=owner)
            return GrantOutcome("existing", balance)

        # 2. DeviceCheck:bit0 已置 = 该设备铸过 → 拒(重装防线的本体)
        if self._devicecheck is not None and device_token:
            result = self._devicecheck.query_two_bits(device_token)
            if result.success and result.bit0:
                return GrantOutcome(
                    "device_blocked", self._store.get_balance(owner=owner))

        # 3. IP 限铸闸 + 原子入账(竞态回退在 store 内)
        granted = self._store.try_grant_trial(
            owner=owner, ip=ip, day=day,
            credits=credits, mint_limit=mint_limit)
        if granted.outcome == "granted":
            # 4. 回写 bit0(失败不回滚:最坏 = 该设备再铸一次,限铸闸封顶)
            if self._devicecheck is not None and device_token:
                if not self._devicecheck.update_two_bits(
                        device_token, bit0=True):
                    logger.warning(
                        "ask.trial_bit_write_failed owner=%s… ip=%s "
                        "(铸造已入账,该设备重装仍可再铸一次,限铸闸兜底)",
                        owner[:8], ip)
            return GrantOutcome("granted", granted.balance)
        if granted.outcome == "existing":
            return GrantOutcome("existing", granted.balance)
        return GrantOutcome("mint_limited", 0)
