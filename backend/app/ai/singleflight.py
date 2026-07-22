"""进程内 LLM 调用 singleflight 合并器(D2 v1.5)。

场景:同一个命盘(content_hash + module + target_date + prompt_hash + provider + model)
在缓存未命中时被并发请求 N 次,若不加合并会发起 N 次 LLM 调用(成本 + 延迟叠加)。

本模块只做**进程内**合并。多 worker 下每个进程独立 inflight 表,跨进程并发无法合并
(那是 v2 Redis 的事)。单进程内的合并仍能消除:客户端短时间重试、同用户多 tab、
负载均衡粘性同 worker 的并发。

错误显式传播(严格遵守 CLAUDE.md):factory 抛什么,等待者就拿什么。
不做异常吞噬、不做 fallback、不做默认值掩盖失败。
"""

from __future__ import annotations

import asyncio
from typing import Awaitable, Callable, TypeVar

T = TypeVar("T")


class SingleflightCoalescer:
    """asyncio.Task 合并器:key → inflight Task。

    线程安全策略:
    - 用 asyncio.Lock 保护 inflight dict 的读写(单 worker 事件循环内串行化)
    - 所有等待者通过 asyncio.shield 共享同一个 Task,避免某个等待者被 cancel
      时连带 cancel 掉正在执行的 inflight
    """

    def __init__(self) -> None:
        self._inflight: dict[object, asyncio.Task[object]] = {}
        self._lock = asyncio.Lock()

    async def coalesce(
        self,
        key: object,
        factory: Callable[[], Awaitable[T]],
    ) -> T:
        """同 key 并发只执行一次 factory,所有调用者共享结果(成功或异常)。

        Args:
            key: 可哈希的缓存键(推荐 tuple,与 InterpretationCache key 对齐)
            factory: 无参 async callable,执行真正的 LLM 调用

        Returns:
            factory 的返回值(所有并发调用者拿到同一份结果)

        Raises:
            factory 抛什么就抛什么(原样传播给所有等待者)
        """
        async with self._lock:
            existing = self._inflight.get(key)
            if existing is not None:
                # shield 防止当前等待者被 cancel 时连带 cancel inflight Task
                return await asyncio.shield(existing)  # type: ignore[no-any-return]
            task = asyncio.ensure_future(factory())
            self._inflight[key] = task

        try:
            return await task  # type: ignore[no-any-return]
        finally:
            async with self._lock:
                # 只删自己创建的 task,防止 race(后到等待者已新建另一个 task)
                if self._inflight.get(key) is task:
                    del self._inflight[key]
