"""LLM 生成每日配额 store,免费/付费双桶(2026-10-07 匿名滥用收口;
2026-10-08 第十四轮起付费同款计数,paid: 前缀分桶)。

威胁模型(P1,已 PoC 实证):免费 module 匿名可无限刷——12 个不同
content_hash 连续请求全部 200 且真烧 12 次 LLM;「每日 10 次」只存在于
iOS 本地 UserDefaults(DailyReadCounter),服务端零感知。

口径(2026-10-07 拍板 30 次/日;2026-10-08 拍板放宽 150 次/日,CGNAT 共享
出口下正常用户不再互相挤兑):
- 只对**真烧 LLM** 的调用计数(缓存命中 / 禁词拦截等零成本路径不计)
- 免费 module 计数;付费 module 同计但独立分桶(2026-10-08 第十四轮
  拍板:付费不再豁免——M4/M5 用户输入不绑 token,换输入即新缓存键新
  调用;付费桶 paid: 前缀、上限 PAID_DAILY_LIMIT,与免费互不挤兑)
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

import logging
import sqlite3

from ..core.ip_digest import ASK_IP_PURPOSE, FREE_QUOTA_IP_PURPOSE, ip_digest

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


# TASK-13(2026-11-27):配额/退款行保留天数。配额与限铸只看当天(day 等值
# 查询,全仓无 >当天的读取——已 grep 确认);保留一周仅供排障,到期删。
RETENTION_DAYS = 7

# bucket 前缀 → ip_digest purpose(ip:/ask-ip: 两族明文存量迁移用;
# 值取 core.ip_digest 单一事实源,与调用点同源防漂移)
_BUCKET_PURPOSE = {"ip": FREE_QUOTA_IP_PURPOSE, "ask-ip": ASK_IP_PURPOSE}


class FreeLLMQuotaStore:
    """free_llm_quota 表:单方法 try_consume(原子条件自增)。"""

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._last_purge_day: str | None = None  # 进程内;每 worker 独立,漏一天无害

    def _migrate_plaintext_buckets(self, conn: sqlite3.Connection) -> int:
        """存量明文 IP 桶 → 带密钥摘要(幂等;与建表同事务,失败上抛)。

        判据:bucket 形如 <前缀>:<值> 且剥前缀后的值含 '.' 或 ':'(明文
        IPv4/IPv6);十六进制摘要两者皆无,重跑自然空集。user: 桶前缀不在
        _BUCKET_PURPOSE,不动。

        撞键合并(2026-11-27 review):部署重叠窗口内旧进程可能给同一
        (IP, day) 写回明文行,与新代码已写的摘要行同 PK——直接 UPDATE 撞
        UNIQUE 会让启动永久失败(行不老化:purge 排在 init_schema 之后)。
        故用 INSERT..SELECT..ON CONFLICT 把计数**相加**进摘要行再删源行
        (两侧都是真实用量,相加是防滥用护栏的保守方向)。
        """
        migrated = 0
        for table in ("free_llm_quota", "free_llm_quota_refunds"):
            rows = conn.execute(
                f"SELECT rowid, bucket FROM {table} "
                f"WHERE bucket LIKE 'ip:%' OR bucket LIKE 'ask-ip:%'"
            ).fetchall()
            updates: list[tuple[str, int]] = []
            for rowid, bucket in rows:
                prefix, _, rest = bucket.partition(":")
                if prefix in _BUCKET_PURPOSE and ("." in rest or ":" in rest):
                    updates.append(
                        (f"{prefix}:{ip_digest(rest, _BUCKET_PURPOSE[prefix])}",
                         rowid))
            for new_bucket, rowid in updates:
                conn.execute(
                    f"INSERT INTO {table} (bucket, day, count) "
                    f"SELECT ?, day, count FROM {table} WHERE rowid = ? "
                    f"ON CONFLICT(bucket, day) DO UPDATE SET "
                    f"count = count + excluded.count",
                    (new_bucket, rowid))
                conn.execute(
                    f"DELETE FROM {table} WHERE rowid = ?", (rowid,))
            migrated += len(updates)
        return migrated

    def purge_old_rows(self, *, force: bool = False) -> int:
        """删 day < 今天(UTC)−RETENTION_DAYS 的行。幂等,返回删除数。

        force=True 跳过进程内当日去重(lifespan 启动显式调);写路径经
        _maybe_purge 每天最多顺带一次,不逐请求 DELETE。
        """
        from datetime import datetime, timedelta, timezone

        now = datetime.now(timezone.utc)  # 单次取值:today/cutoff 不跨午夜错位
        today = now.strftime("%Y-%m-%d")
        if not force and self._last_purge_day == today:
            return 0
        self._last_purge_day = today
        cutoff = (
            now - timedelta(days=RETENTION_DAYS)
        ).strftime("%Y-%m-%d")
        deleted = 0
        with self._connect() as conn:
            for table in ("free_llm_quota", "free_llm_quota_refunds"):
                cursor = conn.execute(
                    f"DELETE FROM {table} WHERE day < ?", (cutoff,))
                deleted += cursor.rowcount
        return deleted

    def _maybe_purge(self) -> None:
        """写路径顺带清理(当日首次写触发,见 purge_old_rows 去重闸)。

        清理走独立连接,成败均不影响主写事务;清理属非关键路径(TASK-13
        任务书允许的显式传播例外):失败记全量 traceback 日志,下一写日
        自愈——不吞进主语义、也不让 DELETE 故障放大成配额 500。"""
        try:
            self.purge_old_rows()
        except Exception:
            logging.getLogger(__name__).exception(
                "quota.purge_old_rows failed(下个写日重试)")

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表(幂等)+ TASK-13 存量明文桶迁移(同事务,失败启动报错)。

        Raises: sqlite3.Error(不吞)。
        """
        with self._connect() as conn:
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_REFUND_TABLE_SQL)
            self._migrate_plaintext_buckets(conn)
            conn.commit()

    def try_consume(self, *, bucket: str, day: str, limit: int) -> bool:
        """尝试消耗 1 次;当日已达 limit 则不修改并返回 False。

        Raises:
            sqlite3.Error: 读写失败(向上抛,路由层包 500,不静默放行)
        """
        self._maybe_purge()
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

    def get_count(self, *, bucket: str, day: str) -> int:
        """读当日已用次数(不消费;十四轮外评 #4 翻译走查前的配额 peek 用)。

        与 try_consume 的差别:纯读不写——翻译端点在目标缓存 miss 后、
        v1 链走查(逐行重渲染,CPU 最重的一步)之前 peek 一次,达限直接
        429,不给达限 bucket 无限重放走查当 CPU 放大器的通道。真烧 LLM
        的计数仍只由 factory 内 try_consume 执行,peek 不引入多计数。

        Raises:
            sqlite3.Error: 读失败(向上抛,不吞)
        """
        with self._connect() as conn:
            row = conn.execute(
                "SELECT count FROM free_llm_quota WHERE bucket=? AND day=?",
                (bucket, day),
            ).fetchone()
        return int(row[0]) if row is not None else 0

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
        self._maybe_purge()
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
