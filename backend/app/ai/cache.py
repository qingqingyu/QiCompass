"""后端 AI 解读 SQLite 缓存(D2 第二级 + i18n 第 8 维度 language)。

- 表结构:
- PK = (content_hash, module, prompt_version, target_date, prompt_hash,
        provider, model, parent_hash, user_input_hash, language)
- target_date 非 daily_fortune 时存空串(避免 NULL 进 PK 歧义)
- prompt_hash 由渲染后的 prompt sha256 得到,避免客户端用同一 content_hash
  携带不同 context 污染跨用户缓存
- provider/model 是缓存身份,切换后不会误用另一家/另一模型的结果
- v1 prompt 系统:parent_hash 隔离 M0 fingerprint 变化;user_input_hash 隔离
  M4/M5 用户输入变化。两字段对老模块默认空串,行为不变。
- language 是 i18n 身份(i18n 决策 3),同 content_hash 不同 language 独立缓存,
  避免英文用户拿到中文缓存

错误显式传播(严格遵守 CLAUDE.md):
- sqlite3 异常不吞,向上抛 → 路由层包成 InterpretationCacheError(500)
- cache get 失败 → 抛 500(不降级为 provider 调用,避免缓存层故障被静默掩盖)
- cache set 失败 → 抛 500(不返回"成功但没缓存",验收要求缓存行为可靠)

线程池策略:
- 每次操作开短连接(with sqlite3.connect(...)),同步,由路由层 run_in_threadpool 包
- 构造时不开连接(避免跨线程持有)
"""

from __future__ import annotations

import sqlite3
from typing import Any

from .cache_key import CacheKey

# 建表语句(幂等,lifespan 启动时执行)
# i18n 改造:新增 language 列 + 加入 PRIMARY KEY
# 注:_drop_legacy_cache_if_needed 会检测老表(缺 language 列)并 drop,
# 老缓存丢失但可重新生成,符合 D2 决策"缓存可再生成,不冒险复用"。
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS interpretation_cache (
    content_hash    TEXT NOT NULL,
    module          TEXT NOT NULL,
    prompt_version  INTEGER NOT NULL,
    target_date     TEXT NOT NULL DEFAULT '',
    prompt_hash     TEXT NOT NULL,
    provider        TEXT NOT NULL,
    model           TEXT NOT NULL,
    parent_hash     TEXT NOT NULL DEFAULT '',
    user_input_hash TEXT NOT NULL DEFAULT '',
    language        TEXT NOT NULL DEFAULT 'zh',
    interpretation  TEXT NOT NULL,
    generated_at    TEXT NOT NULL,
    PRIMARY KEY (
        content_hash, module, prompt_version, target_date, prompt_hash,
        provider, model, parent_hash, user_input_hash, language
    )
);
"""


class InterpretationCache:
    """SQLite AI 解读缓存。

    同步 I/O,每次操作开短连接。路由层应通过 run_in_threadpool 调用。
    """

    def __init__(self, db_path: str):
        """Args:
            db_path: SQLite 文件路径(由 config.DB_PATH 提供)
        """
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        """开短连接 + 设 busy_timeout(5s)缓解并发写锁冲突。

        WAL 模式下读不阻塞写,但并发写仍可能 lock → 默认立即抛 OperationalError。
        busy_timeout 让写操作等待最多 5 秒,减少 500 误报(设计文档 v2 再做 singleflight)。
        注:sqlite3.connect(timeout=5.0) 已内部设置 busy_timeout=5000ms,
        无需再执行 PRAGMA busy_timeout(Python sqlite3 模块行为)。
        """
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表(幂等)。lifespan 启动时调用。

        同时设置 WAL 模式(持久,提升并发读写性能,避免默认 DELETE 模式锁定)。

        Raises:
            sqlite3.Error: 建表失败(不吞,向上抛)
        """
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            _drop_legacy_cache_if_needed(conn)
            conn.execute(CREATE_TABLE_SQL)
            conn.commit()

    def get(self, key: CacheKey) -> dict[str, Any] | None:
        """查缓存。

        Args:
            key: 十维度缓存键(content_hash/module/prompt_version/target_date/
                prompt_hash/provider/model/parent_hash/user_input_hash/language)

        Returns:
            命中 → dict(provider, model, interpretation, generated_at)
            未命中 → None

        Raises:
            sqlite3.Error: 读失败(不吞,向上抛,路由层转 500)
        """
        td = key.target_date or ""
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT provider, model, interpretation, generated_at "
                "FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND prompt_hash=? "
                "AND provider=? AND model=? "
                "AND parent_hash=? AND user_input_hash=? AND language=?",
                (key.content_hash, key.module, key.prompt_version, td,
                 key.prompt_hash, key.provider, key.model,
                 key.parent_hash, key.user_input_hash, key.language),
            ).fetchone()
        if row is None:
            return None
        return {
            "provider": row["provider"],
            "model": row["model"],
            "interpretation": row["interpretation"],
            "generated_at": row["generated_at"],
        }

    def set(self, key: CacheKey, interpretation: str, generated_at: str) -> None:
        """写缓存(INSERT OR REPLACE,同 key 覆盖,幂等)。

        Args:
            key: 十维度缓存键
            interpretation: AI 解读文本
            generated_at: ISO 8601 UTC 时间字符串

        Raises:
            sqlite3.Error: 写失败(不吞,向上抛,路由层转 500)
        """
        td = key.target_date or ""
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO interpretation_cache "
                "(content_hash, module, prompt_version, target_date, prompt_hash, "
                " provider, model, parent_hash, user_input_hash, language, "
                " interpretation, generated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (key.content_hash, key.module, key.prompt_version, td,
                 key.prompt_hash, key.provider, key.model,
                 key.parent_hash, key.user_input_hash, key.language,
                 interpretation, generated_at),
            )
            conn.commit()

    def has_interpretation_text(
        self, content_hash: str, module: str, prompt_version: int,
        language: str, interpretation: str,
        target_date: str | None = None,
    ) -> bool:
        """按文本核验缓存行存在(/api/interpret/translate 服务端原文防伪)。

        不匹配 hash 维度(prompt_hash / provider / model / parent_hash /
        user_input_hash):翻译请求重建的 context 是**目标语言**口径(iOS 侧
        name_a 等字段随语言本地化),服务端算不出原文生成时的 source 键;
        文本级匹配已足以证明「这段原文出自本后端为该盘 / 该模块 / 该语言 /
        该版本生成的内容」,杜绝客户端伪造任意文本经翻译落入共享缓存键。

        target_date 维度(2026-10-02 修复):daily_fortune 的缓存键含日期,
        不比对会让「昨天的 zh 运势原文 + 今天的 target_date」通过防伪,
        译文写进**今天**的共享键——所有设备当天都拿到昨天的运势。空值口径
        与写侧一致(非 daily module 的行恒存 "")。

        Args:
            content_hash: 盘内容寻址哈希
            module: module 名
            prompt_version: 当前 PROMPT_VERSIONS 版本(路由层 STALE 门控已
                保证客户端声明的原文版本 = 当前版本,此处同值收紧)
            language: 原文语言(source_language)
            interpretation: 客户端提交的原文全文(须逐字相等)
            target_date: ISO 日期串;daily_fortune 必传请求的 target_date,
                其他 module 传 None(与缓存写入的空值口径一致)

        Returns:
            True = 存在逐字一致的行;False = 不存在

        Raises:
            sqlite3.Error: 读失败(不吞,向上抛,路由层转 500)
        """
        td = target_date or ""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND language=? AND interpretation=? "
                "LIMIT 1",
                (content_hash, module, prompt_version, td, language,
                 interpretation),
            ).fetchone()
        return row is not None

    def has_interpretation_exact(
        self, content_hash: str, module: str, prompt_version: int,
        language: str, interpretation: str,
        prompt_hash: str, parent_hash: str, user_input_hash: str,
        target_date: str | None = None,
    ) -> bool:
        """翻译防伪收紧版(2026-10-07):按**完整源缓存键**核验原文。

        与 has_interpretation_text 的差别:额外匹配 prompt_hash / parent_hash /
        user_input_hash——这三维由源 context(含链式字段 main_axis / core_loop /
        structure_fingerprint)与 parent_fingerprint / M4-M5 用户输入派生,
        是「攻击者用真盘 + 未绑定链式字段注入生成 → 落在注入键 → 翻译投进
        正常键」通道的关死点。排除 provider / model(服务端配置,非攻击面,
        且防 provider 漂移误杀合法翻译)。

        Args:
            content_hash / module / prompt_version / language / interpretation:
                同 has_interpretation_text(逐字相等)
            prompt_hash / parent_hash / user_input_hash:源语言重渲染后的缓存
                键维度(路由层经 _prepare_prompt_and_key(req, source_language)
                算出,与原文生成时逐字段一致)
            target_date:ISO 日期串;daily_fortune 必传,其他 module 传 None

        Returns:
            True = 完整源键下存在逐字一致的行;False = 不存在

        Raises:
            sqlite3.Error: 读失败(不吞,向上抛,路由层转 500)
        """
        td = target_date or ""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND language=? AND prompt_hash=? "
                "AND parent_hash=? AND user_input_hash=? AND interpretation=? "
                "LIMIT 1",
                (content_hash, module, prompt_version, td, language,
                 prompt_hash, parent_hash, user_input_hash, interpretation),
            ).fetchone()
        return row is not None

    def get_interpretation_by_source_key(
        self, content_hash: str, module: str, prompt_version: int,
        language: str, prompt_hash: str, parent_hash: str,
        user_input_hash: str, target_date: str | None = None,
    ) -> str | None:
        """按**源缓存键**(排除 provider/model)取行文本(2026-10-07)。

        用途:v1 翻译防伪的源键链式推导(interpret.py
        `_derive_v1_source_key`)——从自存源语言上游行提取链式字段。
        键口径与 has_interpretation_exact 完全一致(SELECT interpretation
        而非 1)。

        provider/model 不参与匹配:同键多 provider 行并存时取 generated_at
        最新一行(单 provider 部署下键唯一;多行时若取到的行与客户端当年
        提取链字段的那行不同,下游 prompt_hash 核验不匹配 → 409 降级
        重生成,安全侧收敛)。

        Returns:
            命中 → interpretation 全文;未命中 → None

        Raises:
            sqlite3.Error: 读失败(不吞,向上抛)
        """
        td = target_date or ""
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT interpretation FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND language=? AND prompt_hash=? "
                "AND parent_hash=? AND user_input_hash=? "
                "ORDER BY generated_at DESC LIMIT 1",
                (content_hash, module, prompt_version, td, language,
                 prompt_hash, parent_hash, user_input_hash),
            ).fetchone()
        if row is None:
            return None
        return row["interpretation"]

    def delete(self, key: CacheKey) -> None:
        """删除缓存行(用于清理被禁词污染的坏缓存)。

        Args:
            key: 十维度缓存键

        Raises:
            sqlite3.Error: 删失败(不吞,向上抛)
        """
        td = key.target_date or ""
        with self._connect() as conn:
            conn.execute(
                "DELETE FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND prompt_hash=? "
                "AND provider=? AND model=? "
                "AND parent_hash=? AND user_input_hash=? AND language=?",
                (key.content_hash, key.module, key.prompt_version, td,
                 key.prompt_hash, key.provider, key.model,
                 key.parent_hash, key.user_input_hash, key.language),
            )
            conn.commit()


# i18n 改造:_EXPECTED_COLUMNS 同步加 "language",
# 否则 _drop_legacy_cache_if_needed 会误判新表为 legacy 而 drop。
_EXPECTED_COLUMNS = frozenset({
    "content_hash", "module", "prompt_version", "target_date",
    "prompt_hash", "provider", "model",
    "parent_hash", "user_input_hash", "language",
    "interpretation", "generated_at",
})


def _drop_legacy_cache_if_needed(conn: sqlite3.Connection) -> None:
    """旧表 schema 不匹配(缺列/多列)时丢弃;缓存可再生成,不冒险复用。"""
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='interpretation_cache'"
    ).fetchone()
    if row is None:
        return
    columns = {
        str(col[1])
        for col in conn.execute("PRAGMA table_info(interpretation_cache)").fetchall()
    }
    if columns != _EXPECTED_COLUMNS:
        conn.execute("DROP TABLE interpretation_cache")
