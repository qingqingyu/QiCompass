"""出生钟面时间 → 绝对时刻解析(stdlib zoneinfo,零新依赖)。

Parent 决策: docs/城市搜索设计决策.md Q5(docs/城市搜索-slices/S02)
- 客户端只发**裸钟面时间 + IANA 时区名**,解释责任在后端
  (「客户端不做历法计算」红线)
- 历史规则(1986-91 中国夏令时 / 伦敦 BDST / 美国 2007 前 DST)由 tzdb 自动套用,
  不需要也不应该问用户「你这是夏令时吗」——用户记忆的钟面 = tzdb 记录的实际墙钟

歧义策略(确定性,PEP 495 fold):
- 歧义小时(秋令时回拨重复段,utcoffset fold0 > fold1)→ fold=0 取较早的一次
- 不存在小时(春令时跳过段,fold0 < fold1)→ fold=0 按切换前偏移解释,
  实际绝对时刻落在跳变之后(等效向后平移)

错误显式传播:两类边角 + 切换点附近(±3h)→ dst_flags,由 API 层并入
boundary_warning 提示用户核对;不静默吞。

部署备忘:zoneinfo 是 Python 3.9+ stdlib,但依赖系统 tzdata —— macOS/Linux
开发环境自带零动作;若容器化用 Alpine 镜像,需 apk add tzdata(否则历史
夏令时规则缺失,1986-91 中国盘会算错)。
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

FLAG_AMBIGUOUS = "dst_ambiguous"
FLAG_NONEXISTENT = "dst_nonexistent"
FLAG_NEAR_TRANSITION = "dst_transition"

# 切换点附近的探测窗口(小时)。窗口内 offset 变化 → 提示核对
NEAR_TRANSITION_HOURS = 3


@dataclass(frozen=True)
class ResolvedBirth:
    """钟面时间解析结果。

    aware: 绝对时刻(offset-aware,挂出生地时区)
    dst_flags: 可能含 dst_ambiguous / dst_nonexistent / dst_transition
    """

    aware: datetime
    dst_flags: frozenset[str]


def validate_timezone(name: str) -> ZoneInfo:
    """IANA 时区名校验(pydantic validator 调用,非法 → ValueError → 422)。"""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError, KeyError, OSError) as e:
        raise ValueError(f"timezone 必须是合法 IANA 时区名,收到 {name!r}") from e


def resolve_wall_time(naive: datetime, tz_name: str) -> ResolvedBirth:
    """裸钟面 + IANA 时区名 → 绝对时刻。

    Args:
        naive: 出生钟面时间(必须 naive,带 offset 属于契约违反)
        tz_name: IANA 时区名(须已通过 validate_timezone;此处再验一次,
                 双保险不产生额外成本)

    Raises:
        ValueError: birth_datetime 带 offset / 时区名非法(调用方保证不触发,
                    触发即 500 暴露 bug,不静默)
    """
    if naive.tzinfo is not None and naive.utcoffset() is not None:
        raise ValueError(
            f"birth_datetime 必须是裸钟面时间(naive),收到 {naive.isoformat()};"
            "时区由 timezone 字段解释(S02 契约)"
        )
    zone = validate_timezone(tz_name)

    d0 = naive.replace(tzinfo=zone, fold=0)
    d1 = naive.replace(tzinfo=zone, fold=1)
    off0, off1 = d0.utcoffset(), d1.utcoffset()

    flags: set[str] = set()
    if off0 == off1:
        aware = d0
    elif off0 > off1:
        # 回拨重复段:同一钟面出现两次 → fold=0 较早的一次
        aware = d0
        flags.add(FLAG_AMBIGUOUS)
    else:
        # 跳过段:钟面从未存在 → fold=0 按切换前偏移,绝对时刻落在跳变后
        aware = d0
        flags.add(FLAG_NONEXISTENT)

    base_off = aware.utcoffset()
    for hours in (-NEAR_TRANSITION_HOURS, -2, -1, 1, 2, NEAR_TRANSITION_HOURS):
        probe = (naive + timedelta(hours=hours)).replace(tzinfo=zone)
        if probe.utcoffset() != base_off:
            flags.add(FLAG_NEAR_TRANSITION)
            break

    return ResolvedBirth(aware=aware, dst_flags=frozenset(flags))
