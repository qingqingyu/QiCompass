"""SingleflightCoalescer 单元测试。

覆盖:
- 同 key 并发:factory 只调 1 次,所有调用者拿同一结果
- 异 key 并发:各自独立调用 factory,互不合并
- 异常传播:factory 抛错时所有等待者拿到同一异常,inflight 清理
- 成功后 inflight 清理
- 失败后下次同 key 会重新调 factory(inflight 已清,不被失败永久污染)
"""

from __future__ import annotations

import asyncio

import pytest

from app.ai.singleflight import SingleflightCoalescer


async def test_concurrent_same_key_shares_result():
    """同 key 并发 10 次:factory 只调 1 次,所有调用者拿到同一结果。"""
    sf = SingleflightCoalescer()
    call_count = 0

    async def factory():
        nonlocal call_count
        call_count += 1
        await asyncio.sleep(0.05)  # 模拟 LLM 调用延迟,让并发真正重叠
        return f"result-{call_count}"

    results = await asyncio.gather(*[
        sf.coalesce("k1", factory) for _ in range(10)
    ])

    assert call_count == 1, f"factory 应只调 1 次,实际 {call_count}"
    assert len(results) == 10
    assert all(r == "result-1" for r in results), \
        f"所有调用者应拿到同一结果,实际 {results}"


async def test_different_keys_no_coalesce():
    """不同 key 各自独立调用 factory,不合并。"""
    sf = SingleflightCoalescer()
    calls: list[str] = []

    async def factory(key):
        calls.append(key)
        await asyncio.sleep(0.01)
        return f"result-{key}"

    r1, r2 = await asyncio.gather(
        sf.coalesce("k1", lambda: factory("k1")),
        sf.coalesce("k2", lambda: factory("k2")),
    )

    assert sorted(calls) == ["k1", "k2"], \
        f"不同 key 各自应调 factory 一次,实际 calls={calls}"
    assert r1 == "result-k1"
    assert r2 == "result-k2"


async def test_exception_propagated_to_all_waiters():
    """factory 抛错:所有等待者拿到同一异常类型 + 同一消息,inflight 被清理。"""
    sf = SingleflightCoalescer()
    call_count = 0

    async def factory():
        nonlocal call_count
        call_count += 1
        await asyncio.sleep(0.05)
        raise ValueError(f"boom-{call_count}")

    # 5 个并发等待
    results = await asyncio.gather(*[
        sf.coalesce("k1", factory) for _ in range(5)
    ], return_exceptions=True)

    assert call_count == 1, "factory 应只调 1 次(失败也合并)"
    assert len(results) == 5
    assert all(isinstance(r, ValueError) for r in results), \
        f"所有等待者应拿到 ValueError,实际 {[type(r).__name__ for r in results]}"
    assert all(str(r) == "boom-1" for r in results), \
        f"所有等待者应拿到同一异常消息,实际 {[str(r) for r in results]}"
    assert "k1" not in sf._inflight, "失败后 inflight 应被清理"


async def test_inflight_cleared_after_success():
    """成功后 inflight 表清空。"""
    sf = SingleflightCoalescer()

    async def factory():
        await asyncio.sleep(0.01)
        return "ok"

    result = await sf.coalesce("k1", factory)
    assert result == "ok"
    assert "k1" not in sf._inflight, "成功后 inflight 应被清理"
    assert len(sf._inflight) == 0


async def test_refactory_after_exception():
    """失败后下次同 key 会重新调 factory(inflight 已清,不永久污染)。"""
    sf = SingleflightCoalescer()
    call_count = 0

    async def factory():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise RuntimeError("first fails")
        return f"call-{call_count}"

    # 第一次:失败
    with pytest.raises(RuntimeError, match="first fails"):
        await sf.coalesce("k1", factory)
    assert call_count == 1

    # 第二次:inflight 已清,重新调 factory
    result = await sf.coalesce("k1", factory)
    assert result == "call-2"
    assert call_count == 2

    # 第三次:第二次成功后 inflight 也清了,再调还是新一次
    result3 = await sf.coalesce("k1", factory)
    assert result3 == "call-3"
    assert call_count == 3
