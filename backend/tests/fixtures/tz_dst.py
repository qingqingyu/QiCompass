"""tzdb 时制切换探测共享 helper(S02 测试用)。

程序化发现 fold0 != fold1 的钟面(歧义/跳过段起点),不硬编码切换时刻,
防 tzdb 版本漂移——历史锚点(tzdb 已验证):Asia/Shanghai 1988-04-17
02:00→03:00(跳过段)、1988-09-11 02:00→01:00(重复段),扫描窗口放宽到
96h 防记错周日。
"""

from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def find_dst_fold_minute(zone_name: str, start: datetime, hours: int) -> datetime:
    """在 [start, start+hours) 内逐分钟扫描,返回首个 fold0 != fold1 的钟面。

    Args:
        zone_name: IANA 时区名
        start: 扫描起点(naive 钟面)
        hours: 扫描窗口(小时)

    Raises:
        AssertionError: 窗口内未发现时制切换(显式失败,不静默返回 None)
    """
    zone = ZoneInfo(zone_name)
    t = start
    for _ in range(hours * 60):
        if (t.replace(tzinfo=zone, fold=0).utcoffset()
                != t.replace(tzinfo=zone, fold=1).utcoffset()):
            return t
        t += timedelta(minutes=1)
    raise AssertionError(f"{zone_name} {start}±{hours}h 未发现时制切换")
