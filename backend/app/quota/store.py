"""免费 LLM 生成每日配额 store(2026-10-07 匿名滥用收口)。

威胁模型(P1,已 PoC 实证):免费 module 匿名可无限刷——12 个不同
content_hash 连续请求全部 200 且真烧 12 次 LLM;「每日 10 次」只存在于
iOS 本地 UserDefaults(DailyReadCounter),服务端零感知。

口径(2026-10-07 拍板 30 次/日;2026-10-08 拍板放宽 150 次/日,CGNAT 共享
出口下正常用户不再互相挤兑):
- 只对**真烧 LLM** 的调用计数(缓存命中 / 禁词拦截等零成本路径不计)
- 免费 module 计数;付费 module 豁免(token 绑定后单盘单模块缓存有界)
- bucket:登录请求按 user_id;匿名按客户端 IP(user_local_id 客户端可
  随意伪造,不作 bucket——PoC 中攻击者每请求换 UUID 即绕开)
- 日界:UTC 日期串(防滥用护栏,非产品级配额;产品口径仍在 iOS 本地)
- 退款(2026-10-08 拍板:分类退+防刷上限)走 try_refund,按 (bucket, day)
  的退款次数上限封顶——「构造可触发退款的失败 = 免费烧 LLM」的通道
  每日至多白嫖 REFUND_DAILY_LIMIT 次

实现:与 InterpretationCache / EntitlementStore 同款 SQLite 短连接模式,
多 worker 共库共享计数;先 INSERT OR IGNORE 建零行,再条件 UPDATE
(count < limit 才 +1),rowcount=0 即达限——并发下少量超计数无害
(上限是护栏不是精确账本)。
"""

from __future__ import annotations

import sqlite3

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS free_llm_quota (
    bucket TEXT NOT NULL,
    day    TEXT NOT NULL,
    count  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket, day)
);
"""

# 退款次数表(2026-10-08 分类退+防刷上限):独立于 free_llm_quota,
# 不动既有表结构(CREATE IF NOT EXISTS 幂等,老库零迁移)。
CREATE_REFUND_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS free_llm_quota_refunds (
    bucket TEXT NOT NULL,
    day    TEXT NOT NULL,
    count  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket, day)
);
"""


class FreeLLMQuotaStore:
    """free_llm_quota 表:单方法 try_consume(原子条件自增)。"""

    def __init__(self, db_path: str):
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表(幂等)。 Raises: sqlite3.Error(不吞)。"""
        with self._connect() as conn:
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_REFUND_TABLE_SQL)
            conn.commit()

    def try_consume(self, *, bucket: str, day: str, limit: int) -> bool:
        """尝试消耗 1 次;当日已达 limit 则不修改并返回 False。

        Raises:
            sqlite3.Error: 读写失败(向上抛,路由层包 500,不静默放行)
        """
        with self._connect() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO free_llm_quota (bucket, day, count) "
                "VALUES (?, ?, 0)",
                (bucket, day),
            )
            cursor = conn.execute(
                "UPDATE free_llm_quota SET count = count + 1 "
                "WHERE bucket = ? AND day = ? AND count < ?",
                (bucket, day, limit),
            )
            conn.commit()
            return cursor.rowcount > 0

    def try_refund(self, *, bucket: str, day: str, limit: int) -> bool:
        """退还 1 次,受 (bucket, day) 级退款次数上限保护(2026-10-08 拍板)。

        退款计数先原子自增(refunds.count < limit 才 +1),成功才把配额
        计数减 1;退款次数已达上限 → 返回 False(配额不动,防刷封顶)。
        配额 count 不为负;无记录时 no-op(INSERT 未发生,无行可退,但
        退款计数仍消耗 1 次——无消耗的退款刷计数同样是滥用面)。

        Returns:
            True = 已退回 1 次;False = 当日退款次数已达上限,未退。

        Raises:
            sqlite3.Error: 写失败(向上抛,不静默吞)
        """
        with self._connect() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO free_llm_quota_refunds (bucket, day, count) "
                "VALUES (?, ?, 0)",
                (bucket, day),
            )
            cursor = conn.execute(
                "UPDATE free_llm_quota_refunds SET count = count + 1 "
                "WHERE bucket = ? AND day = ? AND count < ?",
                (bucket, day, limit),
            )
            refunded = cursor.rowcount > 0
            if refunded:
                conn.execute(
                    "UPDATE free_llm_quota SET count = count - 1 "
                    "WHERE bucket = ? AND day = ? AND count > 0",
                    (bucket, day),
                )
            conn.commit()
            return refunded
