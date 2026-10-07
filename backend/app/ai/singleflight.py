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
    - 用 asyncio.Lock 保护 inflight dict 的读写(单 worker 事件循环内串行化);
      锁内不做任何 await(等 LLM 一律出锁后),锁不会被长占
    - 所有调用者(含创建者)通过 asyncio.shield 等待同一个 Task,避免任何
      调用者被 cancel 时连带 cancel 掉正在执行的 inflight
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
        # 锁内只做 dict 读写(无 await 点),取出/创建 task 后**出锁**再等——
        # 若在锁内 await inflight task(2026-10-08 修复前),等待者会持全局锁
        # 等 LLM 调用(约 20s),期间**所有 key** 的 coalesce 全部堵在锁入口,
        # 一对重复请求即可把单 worker 后端退化成串行。
        async with self._lock:
            existing = self._inflight.get(key)
            if existing is not None:
                task = existing
                creator = False
            else:
                task = asyncio.ensure_future(factory())
                self._inflight[key] = task
                creator = True

        try:
            # shield(含创建者):任何调用者被 cancel(如客户端断连)都不
            # 连带 cancel 共享 task——创建者裸 await 会把取消传播给正被其他
            # 等待者共享的 LLM 调用,一起失败(2026-10-08 修复前行为)。
            return await asyncio.shield(task)  # type: ignore[no-any-return]
        finally:
            if creator:
                async with self._lock:
                    # 只删自己创建的 task,防止 race(后到等待者已新建另一个
                    # task)。创建者提前 cancel 时 task 可能仍在跑——删除 key
                    # 会让下个同 key 请求重开一次调用(重复成本,正确性无损),
                    # 优于留着 entry 无人清理的长驻泄漏。
                    if self._inflight.get(key) is task:
                        del self._inflight[key]
