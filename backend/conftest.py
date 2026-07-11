"""根级 conftest:共享 fixtures。"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest


@pytest.fixture
def fixed_now() -> datetime:
    """固定「当前时间」(2026-07-12 12:00 +08:00),供 current_*_pillar 测试。

    选 7 月 12 日确保 current_year_pillar = 丙午(2026 立春后)稳定。
    """
    tz = timezone(timedelta(hours=8))
    return datetime(2026, 7, 12, 12, 0, tzinfo=tz)


@pytest.fixture
def request_id() -> str:
    """固定 request_id,便于断言错误响应。"""
    return "test-req-fixed-0001"


@pytest.fixture
def tz8():
    return timezone(timedelta(hours=8))
