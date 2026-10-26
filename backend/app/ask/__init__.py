"""问事(今日页问事窗)钱包与防刷层——S4b-2,2026-10-25。

口径事实源:MONETIZATION.md §问事窗(2026-10-25 拍板)。
- store:ask_credits 钱包/限铸闸/购买留痕/重复问 history 四表(纯 SQLite)
- devicecheck:Apple DeviceCheck 两比特接口(跨重装设备指纹,零新依赖——
  pyjwt + cryptography 已在 requirements)
- service:试用铸造编排(DeviceCheck 查询 → 限铸闸 → 入账 → 回写 bit)
"""
