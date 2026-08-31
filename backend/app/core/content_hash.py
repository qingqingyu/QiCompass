"""D1 内容寻址 hash。

定义:`sha256(birth_2h_bucket + utcoffset + gender + longitude + zi_hour_rule)`
- birth_2h_bucket = f"{bucket_date}|{shichen_bucket(hour)}"  —— 传统时辰桶
- zi_next_day 下 23:00-23:59 的子时桶日期归次日,避免与同日 00:00-00:59 碰撞
- 桶函数 shichen_bucket 在 true_solar_time.py 中定义,两处共享
- 用输入时间(原值),不用真太阳时调整后的时间
- utcoffset(S02 增):同一墙钟桶在不同时区解释下是**不同绝对时刻**,
  真太阳时(UTC + 经度×4min + EoT)随之不同,可能落在不同时辰桶 →
  不带 offset 会 hash 碰撞(Asia/Shanghai 夏令时 +9 vs Etc/GMT-8 同桶同经度)。
  offset 进 hash 后,不同时区解释的盘自然分叉;同区同时辰仍共享(D1 语义保留)
- 不含 schema_version(D1:跨用户共享缓存命中率最大)
- canonical JSON:sort_keys + 固定精度(经度 6 位)+ UTF-8
- hour_known=False(时辰未知,2026-08-31):2h 时辰桶不参与,日期 + late_night
  三态参与;hour_known=True 路径 hash 公式不变(见 compute_content_hash)

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
                          zi_hour_rule: str,
                          hour_known: bool = True,
                          late_night: bool | None = None) -> str:
    """计算 contentHash。

    Args:
        birth: 出生本地时间(timezone-aware;hour_known=false 时调用方
               应传 12:00 占位归一后的值,见 bazi_engine)
        gender: "male" | "female"
        longitude: 经度(东正西负)
        zi_hour_rule: 子时规则
        hour_known: 是否知道出生时刻(docs/时辰未知设计决策.md)。
                    False 时 2h 时辰桶**不参与**(时辰未知,桶无意义),
                    日期 + late_night 参与;True 路径 hash 公式不变
        late_night: 「半夜出生」三态(True/False/None)。决定日柱歧义状态,
                    不同答案输出不同 → 不进 hash 会同 hash 不同输出(缓存碰撞),
                    必须参与(仅 hour_known=false 时入 payload)

    Returns:
        64 字符 hex sha256

    Raises:
        ValueError: birth 非 offset-aware(utcoffset 是 hash 输入,
                    naive 时间属于契约违反,显式报错不静默)
    """
    if birth.utcoffset() is None:
        raise ValueError(
            f"compute_content_hash 要求 offset-aware birth(收到 naive {birth});"
            "钟面→绝对时刻的解释在 API 层完成(S02 契约)")
    if hour_known:
        # ---- 已知时辰:hash 公式不变(老缓存/老权益兼容)----
        payload = {
            "birth_2h_bucket": birth_two_hour_bucket(birth, zi_hour_rule),
            # S02:绝对时刻归因(防同墙钟不同时区解释的 hash 碰撞,见模块 docstring)
            "utcoffset_minutes": int(birth.utcoffset().total_seconds() // 60),
            "gender": gender,
            # 经度固定 6 位小数,避免浮点抖动影响 hash 稳定性
            "longitude": round(longitude, 6),
            "zi_hour_rule": zi_hour_rule,
        }
    else:
        # ---- 时辰未知:时辰桶不参与,日期 + late_night 参与 ----
        # utcoffset/longitude 仍参与:占位 12:00 的真太阳时解释随两者变化,
        # 可能落在不同日/节气(S02 双排盘歧义标记预留位:节气边界歧义命中后
        # 在此 payload 追加标记字段,不动 True 路径)
        payload = {
            "hour_known": False,
            "birth_date": (
                f"{birth.year:04d}-{birth.month:02d}-{birth.day:02d}"
            ),
            "late_night": late_night,
            "utcoffset_minutes": int(birth.utcoffset().total_seconds() // 60),
            "gender": gender,
            "longitude": round(longitude, 6),
            "zi_hour_rule": zi_hour_rule,
        }
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False,
                           separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
