"""PR3.1 跨设备命盘同步 Pydantic models。"""

from __future__ import annotations

from pydantic import BaseModel, Field


class ChartSyncData(BaseModel):
    """跨设备同步的命盘数据(ChartSnapshot + UserSnapshotLink 合并)。

    iOS SwiftData:
    - ChartSnapshot:contentHash / schemaVersion / birthSolarTime / gender /
      cityLongitude / ziHourRule / calcRuleSnapshot(Data)/ payload(Data)
    - UserSnapshotLink:alias

    JSON 序列化策略:
    - calcRuleSnapshot(Data)→ Base64 字符串(避免 JSON 二进制)
    - payload(Data)→ JSON 字符串(已经是 JSON Data,直接 utf-8 decode)
    - birthSolarTime / createdAt → ISO 8601 字符串
    """

    content_hash: str = Field(..., description="ChartSnapshot.contentHash(内容寻址 ID)")
    alias: str = Field(..., description="UserSnapshotLink.alias(我自己/妈妈/男友)")
    schema_version: int = Field(..., description="ChartSnapshot.schemaVersion")
    birth_solar_time: str = Field(..., description="ISO 8601 真太阳时出生时间")
    gender: str = Field(..., description="male / female")
    city_longitude: float = Field(..., description="城市经度")
    city_timezone: str | None = Field(
        None, description="出生地 IANA 时区(S02 契约,S03 起 iOS 随快照同步;老数据 NULL)")
    zi_hour_rule: str = Field(..., description="zi_next_day / zero_oclock")
    calc_rule_snapshot_base64: str = Field(
        ..., description="ChartSnapshot.calcRuleSnapshot(Data)→ Base64 字符串"
    )
    payload_json: str = Field(
        ..., description="ChartSnapshot.payload(JSON Data)→ UTF-8 字符串"
    )
    created_at: str = Field(..., description="iOS 端 createdAt(ISO 8601)")


class SyncPullResponse(BaseModel):
    """POST /api/sync/pull 响应。"""

    user_id: str
    charts: list[ChartSyncData]


class SyncPushRequest(BaseModel):
    """POST /api/sync/push 请求。"""

    charts: list[ChartSyncData] = Field(
        ..., description="客户端所有命盘(全量,后端 UPSERT)"
    )


class SyncPushResponse(BaseModel):
    """POST /api/sync/push 响应。"""

    user_id: str
    upserted_count: int = Field(..., description="实际新增/更新行数")
    total_count: int = Field(..., description="云端总行数(包含本次未传的)")
