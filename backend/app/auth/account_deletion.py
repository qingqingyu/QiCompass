"""账号删除:跨表数据清除(2026-11-24,docs/账号删除端点设计决策 §2/§3 拍板)。

单一 SQLite 文件(DB_PATH)承载全部表 → 本模块开**一个连接一个事务**完成
全部删除/匿名化,中途任一步失败整体回滚(不半删)。

表清单与口径(§1 数据清单 + §3 外评拍板,表 schema 归属文件在括号):
- qicompass_user(auth/user_store):整行删
- user_chart_sync(sync/store):整行删(**含完整出生数据,最强敏感**)
- entitlement(entitlement/store):**匿名化保留**(交易台账):is_active=0 +
  revoked_at=now + user_id=NULL + user_local_id/content_hash→哨兵 'deleted'
  (content_hash 可穷举还原出生信息);另覆盖 DB 内已关联的 legacy
  user_id-NULL 行(user_local_id 取自本账号已关联行,不信客户端上报值)
- ask_purchases(ask/store):匿名化保留(owner→'deleted';退款 webhook
  与对账仍可用)
- ask_wallet / ask_history(ask/store):整行删(owner = 'user:<id>');
  ask_trial_mints 实际按 (ip, day) 计数**无 owner 列**,与账号无挂钩不动;删 history 前先按 (chart_hash, question_hash) 对清
  ask_answer_cache(答案复述用户个人处境,§3.2 含文本缓存)
- interpretation_cache(ai/cache):按用户盘哈希删 **user_input_hash 非空**
  的行 + 合盘模块行(含用户自输入文本;纯盘面派生行保留——跨用户共享)
- free_llm_quota / refunds(quota/store):删 user: 前缀桶(IP 桶保留防滥用)

user_id 行最后删且 rowcount=0 显式抛错(账号不存在 → 全量回滚)。
"""

from __future__ import annotations

import logging
import sqlite3
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

# 哨兵值:匿名化后 linkage 列的占位(非 NULL——列多为 NOT NULL,且
# 哨兵可与「真实但匿名的遗留 NULL」区分)
DELETED_SENTINEL = "deleted"

# 合盘模块(prompts.COMPATIBILITY_MODULES 单一事实源的镜像;此处取值
# 是刻意的独立清单——删除 SQL 不 import prompts(引擎层),漂移由
# test_compat_module_names_match_prompts 锁定)
_COMPAT_MODULES_FOR_DELETION = (
    "compatibility", "compatibility_free", "compatibility_paid",
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def delete_user_data(db_path: str, user_id: str) -> dict[str, int]:
    """删除/匿名化该账号的全部服务端数据(单事务;失败回滚)。

    Args:
        db_path:共享 SQLite 文件路径(全部 store 同文件)
        user_id:qicompass_user.id

    Returns:
        {表名: 受影响行数} 供审计日志

    Raises:
        ValueError:账号不存在(rowcount=0)→ 整体回滚
        sqlite3.Error:任一语句失败(向上抛,事务回滚)
    """
    stats: dict[str, int] = {}
    owner = f"user:{user_id}"
    now = _now_iso()

    # isolation_level=None + 显式 BEGIN:全部 DML 钉在一个事务里,
    # with 块退出时 commit(异常时 rollback 由 except 分支显式执行)
    conn = sqlite3.connect(db_path, timeout=5.0, isolation_level=None)
    try:
        conn.execute("BEGIN IMMEDIATE")

        # ---- 1. 收集原料(删表前)----
        sync_charts = [
            r[0] for r in conn.execute(
                "SELECT content_hash FROM user_chart_sync WHERE user_id = ?",
                (user_id,))
        ]
        ent_rows = conn.execute(
            "SELECT content_hash, user_local_id FROM entitlement WHERE user_id = ?",
            (user_id,),
        ).fetchall()
        ent_charts = {r[0] for r in ent_rows if r[0]}
        # 本账号已关联的 user_local_id(DB 派生,不信客户端上报——§5.3)
        linked_local_ids = {r[1] for r in ent_rows if r[1]}
        chart_hashes = set(sync_charts) | ent_charts

        # ---- 2. user_chart_sync(出生数据,整删)----
        stats["user_chart_sync"] = conn.execute(
            "DELETE FROM user_chart_sync WHERE user_id = ?", (user_id,)).rowcount

        # ---- 3. entitlement 匿名化(交易台账保留)----
        n = conn.execute(
            "UPDATE entitlement SET is_active = 0, revoked_at = ?, "
            "user_id = NULL, user_local_id = ?, content_hash = ? "
            "WHERE user_id = ?",
            (now, DELETED_SENTINEL, DELETED_SENTINEL, user_id)).rowcount
        # legacy 行:user_id 仍 NULL 但 user_local_id 属于本账号
        # (backfill 前的老购买;local_id 集合来自上一步 DB 查询)
        for local_id in linked_local_ids:
            n += conn.execute(
                "UPDATE entitlement SET is_active = 0, revoked_at = ?, "
                "user_local_id = ?, content_hash = ? "
                "WHERE user_id IS NULL AND user_local_id = ?",
                (now, DELETED_SENTINEL, DELETED_SENTINEL, local_id)).rowcount
        stats["entitlement"] = n

        # ---- 4. ask_purchases 匿名化(退款对账保留)----
        stats["ask_purchases"] = conn.execute(
            "UPDATE ask_purchases SET owner = ? WHERE owner = ?",
            (DELETED_SENTINEL, owner)).rowcount

        # ---- 5. 含用户文本的问事缓存 + 历史 ----
        pairs = conn.execute(
            "SELECT DISTINCT chart_hash, question_hash FROM ask_history "
            "WHERE owner = ?", (owner,)).fetchall()
        n = 0
        for chart_hash, question_hash in pairs:
            n += conn.execute(
                "DELETE FROM ask_answer_cache "
                "WHERE chart_hash = ? AND question_hash = ?",
                (chart_hash, question_hash)).rowcount
        stats["ask_answer_cache"] = n
        stats["ask_history"] = conn.execute(
            "DELETE FROM ask_history WHERE owner = ?", (owner,)).rowcount

        # ---- 6. interpretation_cache:含自输入文本的行 + 合盘行 ----
        if chart_hashes:
            placeholders = ", ".join("?" * len(chart_hashes))
            compat_ph = ", ".join("?" * len(_COMPAT_MODULES_FOR_DELETION))
            stats["interpretation_cache"] = conn.execute(
                f"DELETE FROM interpretation_cache "
                f"WHERE content_hash IN ({placeholders}) "
                f"AND (user_input_hash != '' "
                f"     OR module IN ({compat_ph}))",
                (*chart_hashes, *_COMPAT_MODULES_FOR_DELETION)).rowcount
        else:
            stats["interpretation_cache"] = 0

        # ---- 6b. 合盘缓存归属联动清理(2026-11-25 拍板 #1):生成期记了
        #      (compat_hash, user_id),这里反查并删含对方称呼的 compat 缓存行
        #      (免费 + 付费 + 翻译行),再清归属记录本身
        compat_hashes = [
            r[0] for r in conn.execute(
                "SELECT compatibility_hash FROM compat_cache_ownership "
                "WHERE user_id = ?", (user_id,))
        ]
        if compat_hashes:
            compat_ph = ", ".join("?" * len(compat_hashes))
            stats["compat_cache"] = conn.execute(
                f"DELETE FROM interpretation_cache "
                f"WHERE content_hash IN ({compat_ph}) "
                f"AND module IN ({', '.join('?' * len(_COMPAT_MODULES_FOR_DELETION))})",
                (*compat_hashes, *_COMPAT_MODULES_FOR_DELETION)).rowcount
        else:
            stats["compat_cache"] = 0
        stats["compat_cache_ownership"] = conn.execute(
            "DELETE FROM compat_cache_ownership WHERE user_id = ?",
            (user_id,)).rowcount

        # ---- 7. ask 钱包(铸造表 ask_trial_mints 按 (ip, day) 计数,无 owner
        #      列、与账号无挂钩,不属账号数据,不动)----
        stats["ask_wallet"] = conn.execute(
            "DELETE FROM ask_wallet WHERE owner = ?", (owner,)).rowcount

        # ---- 8. 免费 LLM 配额(user: 桶;IP 桶保留防滥用)----
        stats["free_llm_quota"] = conn.execute(
            "DELETE FROM free_llm_quota WHERE bucket = ?", (owner,)).rowcount
        stats["free_llm_quota_refunds"] = conn.execute(
            "DELETE FROM free_llm_quota_refunds WHERE bucket = ?",
            (owner,)).rowcount

        # ---- 9. user 行最后删(不存在 → 抛错整体回滚)----
        stats["qicompass_user"] = conn.execute(
            "DELETE FROM qicompass_user WHERE id = ?", (user_id,)).rowcount
        if stats["qicompass_user"] == 0:
            raise ValueError(
                f"账号不存在(id={user_id[:8]}…),无数据可删——事务回滚")

        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            # BEGIN IMMEDIATE 本身失败(锁超时等)时无活动事务可回滚——
            # 此时唯一正确动作是保留并上抛**原始**异常,不被本条 ROLLBACK
            # 的二次报错掩盖(错误显式传播:报原始的,不报掩盖后的)
            logger.warning(
                "account.deletion.rollback_unavailable(无活动事务,保留原始异常)")
        raise
    finally:
        conn.close()

    logger.info(
        "account.deleted user_id_prefix=%s stats=%s",
        user_id[:8], stats,
    )
    return stats
