"""D1 内容寻址 hash。

定义:`sha256(birth_2h_bucket + gender + longitude + zi_hour_rule)`
- birth_2h_bucket = f"{bucket_date}|{shichen_bucket(hour)}"  —— 传统时辰桶
- zi_next_day 下 23:00-23:59 的子时桶日期归次日,避免与同日 00:00-00:59 碰撞
- 桶函数 shichen_bucket 在 true_solar_time.py 中定义,两处共享
- 用输入时间(原值),不用真太阳时调整后的时间
- 不含 schema_version(D1:跨用户共享缓存命中率最大)
- canonical JSON:sort_keys + 固定精度(经度 6 位)+ UTF-8

同一输入永远同一输出 —— 满足 CLAUDE.md 确定性约束。
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta

from .true_solar_time import shichen_bucket


def birth_two_hour_bucket(birth: datetime, zi_hour_rule: str = "zi_next_day") -> str:
    """传统时辰桶 key(2 小时粒度,对齐子丑寅卯...边界)。

    用本地日历组件(输入时间的时区)。
    zi_next_day 规则下,23 点晚子时归次日桶;否则 00:30 和同日 23:30
    会生成同一个 YYYY-MM-DD|0,污染 ChartSnapshot / AI 缓存。
    桶函数 shichen_bucket 与 true_solar_time.py 的边界检测共享,避免分叉。
    """
    if zi_hour_rule not in ("zi_next_day", "zi_same_day"):
        raise ValueError(f"未知 zi_hour_rule: {zi_hour_rule!r}")

    bucket_date = birth
    if zi_hour_rule == "zi_next_day" and birth.hour == 23:
        bucket_date = birth + timedelta(days=1)

    return (
        f"{bucket_date.year:04d}-{bucket_date.month:02d}-{bucket_date.day:02d}|"
        f"{shichen_bucket(birth.hour)}"
    )


def compute_content_hash(birth: datetime, gender: str, longitude: float,
                          zi_hour_rule: str) -> str:
    """计算 contentHash。

    Args:
        birth: 出生本地时间(timezone-aware)
        gender: "male" | "female"
        longitude: 经度(东正西负)
        zi_hour_rule: 子时规则

    Returns:
        64 字符 hex sha256
    """
    payload = {
        "birth_2h_bucket": birth_two_hour_bucket(birth, zi_hour_rule),
        "gender": gender,
        # 经度固定 6 位小数,避免浮点抖动影响 hash 稳定性
        "longitude": round(longitude, 6),
        "zi_hour_rule": zi_hour_rule,
    }
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False,
                           separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
