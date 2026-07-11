"""D1 内容寻址 hash。

定义:`sha256(birth_2h_bucket + gender + longitude + zi_hour_rule)`
- birth_2h_bucket = f"{YYYY-MM-DD}|{hour//2}"  —— 2 小时时辰桶
- 用输入时间(原值),不用真太阳时调整后的时间
- 不含 schema_version(D1:跨用户共享缓存命中率最大)
- canonical JSON:sort_keys + 固定精度(经度 6 位)+ UTF-8

同一输入永远同一输出 —— 满足 CLAUDE.md 确定性约束。
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime


def birth_two_hour_bucket(birth: datetime) -> str:
    """2 小时时辰桶 key。用本地日历组件(输入时间的时区)。"""
    return f"{birth.year:04d}-{birth.month:02d}-{birth.day:02d}|{birth.hour // 2}"


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
        "birth_2h_bucket": birth_two_hour_bucket(birth),
        "gender": gender,
        # 经度固定 6 位小数,避免浮点抖动影响 hash 稳定性
        "longitude": round(longitude, 6),
        "zi_hour_rule": zi_hour_rule,
    }
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False,
                           separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
