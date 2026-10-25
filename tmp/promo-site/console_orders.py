"""接单台(console)队列存储与解析——Reddit「免费解读」帖的批量收单侧。

2026-10-25 加,配合每周一轮免费解读的宣传打法:
粘贴评论原文 → 结构化(确定性提取优先,LLM 兜底由 main.py 注入 client) →
flagged 项人工在 /console 页修正 → main.py 批量跑 /ask 同款链路出结果。

边界(2026-10-25 拍板):自动化到「生成完、待发送」为止;
发送动作与发送前人工过目永远留人,不在本模块范围。

错误显式传播原则(第 1 步 review 2026-10-25 后收紧):
- 解析不确定的字段绝不静默填默认。缺字段/字段模糊/裸 12h 歧义/
  多日期并存/农历原文/时辰与钟点矛盾 → 一律 review + note 写明原因;
- SQL 列名白名单(update_fields),status 值显式 ValueError(不用 assert);
- 连接生命周期:每操作独立连接,try/finally 关闭(与 main._search_cities
  同款;sqlite3 的 `with conn:` 只是事务上下文,不关连接)。

存储:data/console.db(SQLite,data/ 在 gitignore,仅本机)。
线程模型:每操作独立连接(check_same_thread 无虞);FastAPI 路由侧
调用同步函数时按 main.py 先例自行包 run_in_threadpool(调用方责任)。
"""

from __future__ import annotations

import re
import sqlite3
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

_DB_PATH = Path(__file__).resolve().parent / "data" / "console.db"
_CITY_DB_PATH = Path(__file__).resolve().parent / "data" / "cities.db"

# 状态机:review(待人工) → ready(可生成) → running → done / failed
STATUSES = ("review", "ready", "running", "done", "failed")

# update_fields 允许人工/流程修改的列(白名单;id/created_at 不可改,
# updated_at 自动盖戳)。列名外的键显式 ValueError——键名直接拼进 SET
# 子句,白名单是唯一的注入防线。
_MUTABLE_COLUMNS = frozenset({
    "username", "status", "note", "birth_date", "birth_time", "gender",
    "city", "city_tz", "longitude", "tz_offset", "question",
    "result", "forbidden_notes", "error",
})

_SCHEMA = """
CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL DEFAULT '',
    raw_text TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'review',
    note TEXT NOT NULL DEFAULT '',
    birth_date TEXT,
    birth_time TEXT,
    gender TEXT,
    city TEXT,
    city_tz TEXT,
    longitude REAL,
    tz_offset REAL,
    question TEXT,
    result TEXT,
    forbidden_notes TEXT NOT NULL DEFAULT '',
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
)
"""

_inited = False


# ---------- 连接与建表 ----------

def _ensure_schema() -> None:
    """建表一次(幂等)。data/ 目录不存在则创建(cities.db 缺失是调用方
    关心的另一件事,这里只管自己的库)。"""
    global _inited
    if _inited:
        return
    _DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(_DB_PATH)) as conn:
        conn.execute(_SCHEMA)
        conn.commit()
    _inited = True


def _write(sql: str, params: tuple = ()) -> int:
    """写操作:独立连接,提交后关闭;返回 lastrowid(insert 用)。"""
    _ensure_schema()
    with closing(sqlite3.connect(_DB_PATH)) as conn:
        cur = conn.execute(sql, params)
        rowid = cur.lastrowid or 0
        conn.commit()
        return rowid


def _write_rowcount(sql: str, params: tuple = ()) -> int:
    """写操作,返回受影响行数(条件更新「是否真正写入」判定用)。"""
    _ensure_schema()
    with closing(sqlite3.connect(_DB_PATH)) as conn:
        cur = conn.execute(sql, params)
        n = cur.rowcount
        conn.commit()
        return n


def _read(sql: str, params: tuple = ()) -> list[sqlite3.Row]:
    """读操作:独立连接,用完即关。"""
    _ensure_schema()
    with closing(sqlite3.connect(_DB_PATH)) as conn:
        conn.row_factory = sqlite3.Row
        return conn.execute(sql, params).fetchall()


def _check_status(status: str) -> None:
    if status not in STATUSES:
        raise ValueError(f"未知订单状态:{status!r}(必须 {'/'.join(STATUSES)})")


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


# ---------- CRUD ----------

def insert_order(rec: dict[str, Any]) -> int:
    """插入一单。rec 允许字段缺省(NULL),状态由 finalize_record 判定。"""
    status = rec.get("status") or "review"
    _check_status(status)
    now = _now()
    return _write(
        """INSERT INTO orders
           (username, raw_text, status, note, birth_date, birth_time,
            gender, city, city_tz, longitude, tz_offset, question,
            created_at, updated_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            rec.get("username") or "", rec.get("raw_text") or "",
            status, (rec.get("note") or "")[:500],
            rec.get("birth_date"), rec.get("birth_time"),
            rec.get("gender"), rec.get("city"), rec.get("city_tz"),
            rec.get("longitude"), rec.get("tz_offset"),
            rec.get("question"), now, now,
        ),
    )


def _build_set_clause(fields: dict[str, Any]) -> tuple[list[str], list[Any]]:
    """校验字段(白名单 + status 值)并构建 SET 子句。update_fields 与
    update_fields_if_not_status 共用,校验只有一份实现。"""
    if not fields:
        raise ValueError("fields 不能为空")
    bad = set(fields) - _MUTABLE_COLUMNS
    if bad:
        raise ValueError(f"update_fields 非法列名:{sorted(bad)}")
    if "status" in fields:
        _check_status(fields["status"])
    sets, vals = [], []
    for k, v in fields.items():
        if k == "note":
            v = (v or "")[:500]
        sets.append(f"{k} = ?")
        vals.append(v)
    sets.append("updated_at = ?")
    vals.append(_now())
    return sets, vals


def update_fields(order_id: int, fields: dict[str, Any]) -> None:
    """更新指定字段。列名必须命中 _MUTABLE_COLUMNS 白名单(注入防线);
    status 值走同一显式校验。"""
    if not fields:
        return
    sets, vals = _build_set_clause(fields)
    vals.append(order_id)
    _write(f"UPDATE orders SET {', '.join(sets)} WHERE id = ?", tuple(vals))


def update_fields_if_not_status(order_id: int, fields: dict[str, Any],
                                forbidden_status: str) -> bool:
    """同 update_fields,但行处于 forbidden_status 时整体拒收;返回是否写入。

    人工修正入口用:订单已被批量 runner 抢成 running 后,迟到的表单提交
    直接拒——把「读取→写入」间隙内的状态翻转(毫秒级 TOCTOU)也关掉,
    而不只是入口处的肉眼检查。
    """
    _check_status(forbidden_status)
    sets, vals = _build_set_clause(fields)
    n = _write_rowcount(
        f"UPDATE orders SET {', '.join(sets)} WHERE id = ? AND status != ?",
        (*vals, order_id, forbidden_status))
    return n > 0


def transition_status(order_id: int, from_status: str, to_status: str) -> bool:
    """条件状态迁移:行仍是 from_status 才写成 to_status;返回是否迁移成功。

    批量 runner 抢单用(ready→running):批量启动后操作者把某单改成
    review/删除的,抢单自然失败跳过——runner 不覆盖人工决定,也不拿
    启动时的快照旧数据跑单(迁移成功后调用方应重取行)。
    """
    _check_status(from_status)
    _check_status(to_status)
    n = _write_rowcount(
        "UPDATE orders SET status = ?, updated_at = ? "
        "WHERE id = ? AND status = ?",
        (to_status, _now(), order_id, from_status))
    return n > 0


def set_status(order_id: int, status: str, **extras: Any) -> None:
    _check_status(status)
    update_fields(order_id, {"status": status, **extras})


def delete_order(order_id: int) -> None:
    _write("DELETE FROM orders WHERE id = ?", (order_id,))


def get_order(order_id: int) -> sqlite3.Row | None:
    rows = _read("SELECT * FROM orders WHERE id = ?", (order_id,))
    return rows[0] if rows else None


def list_orders(limit: int = 500) -> list[sqlite3.Row]:
    """全部订单,新在前(接单台主视图);封顶防跑数月后全量载入。"""
    return _read(
        "SELECT * FROM orders ORDER BY id DESC LIMIT ?", (int(limit),))


def list_by_status(status: str) -> list[sqlite3.Row]:
    _check_status(status)
    return _read(
        "SELECT * FROM orders WHERE status = ? ORDER BY id", (status,))


def status_counts() -> dict[str, int]:
    # ORDER BY 保证行序稳定 → dict 键序稳定(页面轮询按 JSON 文本比对,
    # 键序漂移会造成假阳性整页刷新)
    rows = _read(
        "SELECT status, COUNT(*) AS n FROM orders GROUP BY status ORDER BY status")
    return {r["status"]: r["n"] for r in rows}


# ---------- 评论切块 ----------

def split_blocks(blob: str) -> list[str]:
    """粘贴原文 → 评论块列表。

    首选分隔符:单独一行 ---;无分隔符时退化为按空行切(单条评论内部
    含空行会被切碎——所以 UI 上要求用 --- 分隔,退化只是兜底不静默:块数
    会在页面上可见,操作者可目检)。
    """
    text = blob.strip()
    if not text:
        return []
    if re.search(r"^\s*-{3,}\s*$", text, flags=re.M):
        parts = re.split(r"^\s*-{3,}\s*$", text, flags=re.M)
    else:
        parts = re.split(r"\n\s*\n", text)
    blocks = []
    for p in parts:
        cleaned = "\n".join(
            re.sub(r"^\s*>+\s?", "", line) for line in p.strip().splitlines()
        ).strip()
        if cleaned:
            blocks.append(cleaned)
    return blocks


# ---------- 确定性字段提取 ----------

# 月名:全称+缩写,longest-first 交替,\b 双侧防 "Maybe" 命中 "May"
_MONTH_WORDS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5,
    "june": 6, "july": 7, "august": 8, "september": 9, "october": 10,
    "november": 11, "december": 12,
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7,
    "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
}
_MONTH_ALT = "|".join(sorted(_MONTH_WORDS, key=len, reverse=True))

# 时辰 → 中点时刻(与 App 表单同口径:子时→00:00,见 ask_form 时辰选点)
_SHICHEN_MIDPOINT = {
    "子": 0, "丑": 2, "寅": 4, "卯": 6,
    "辰": 8, "巳": 10, "午": 12, "未": 14,
    "申": 16, "酉": 18, "戌": 20, "亥": 22,
}
_BRANCHES = "".join(_SHICHEN_MIDPOINT)

# 模糊时段词:出现且无精确时刻 → 强制 review(不猜中点)
_FUZZY_HOUR_WORDS = (
    "天刚亮", "黎明", "清晨", "傍晚", "黄昏", "深夜", "半夜", "午夜",
    "dawn", "sunrise", "daybreak", "dusk", "sunset",
)
# 农历标记:命中即 review(本工具不自动换算,人工换算后回填)
_LUNAR_MARKERS = re.compile(r"农历|農曆|阴历|陰曆|lunar", re.I)

_RE_USERNAME = re.compile(
    r"(?:^|[\s([<])(?:/u/|u/|@)([A-Za-z0-9_-]{3,20})\b")
_RE_DATE_ZH = re.compile(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?")
_RE_DATE_ISO = re.compile(r"\b(\d{4})([-/.])(\d{1,2})\2(\d{1,2})\b")
_RE_DATE_EN1 = re.compile(
    rf"\b({_MONTH_ALT})\.?,?\s+(\d{{1,2}})(?:st|nd|rd|th)?\s*,?\s+(\d{{4}})\b",
    re.I)
_RE_DATE_EN2 = re.compile(
    rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+({_MONTH_ALT})\.?\s*,?\s*(\d{{4}})\b",
    re.I)
_RE_DATE_US = re.compile(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b")
_RE_TIME_HHMM = re.compile(
    r"\b(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?\b", re.I)
_RE_TIME_ZH = re.compile(
    r"(上午|下午|早上|凌晨|中午|正午|午后|晚上|傍晚|黄昏)?\s*"
    r"(\d{1,2})\s*[点时]\s*(\d{1,2})?\s*分?\s*半?")
_RE_SHICHEN = re.compile(rf"([{_BRANCHES}])\s*时")


def _valid_ymd(y: int, m: int, d: int) -> str | None:
    """历法校验 + 归一化 YYYY-MM-DD;越界返回 None(调用方负责 note)。"""
    try:
        return datetime(y, m, d).strftime("%Y-%m-%d")
    except ValueError:
        return None


def _collect_dates(text: str, notes: list[str]) -> tuple[list[str], bool]:
    """收集全部可识别日期(去重保序)+ 歧义标记。

    返回 (found, ambiguous):ambiguous=True 表示日期解读存在不可判定的
    二义(多日期并存 / 斜杠日期月日都 ≤12 的 M-D 换位歧义),调用方
    必须压 review;D/M 可判定的(如 13/05)与单义格式不算歧义。
    """
    found: list[str] = []
    ambiguous = False

    def _push(y: int, m: int, d: int, why: str | None) -> None:
        iso = _valid_ymd(y, m, d)
        if iso is None:
            notes.append(f"日期 {y}-{m}-{d} 历法越界(如 13 月/2 月 30 日),置空待人工")
            return
        if why:
            notes.append(why)
        if iso not in found:
            found.append(iso)

    for m_ in _RE_DATE_ZH.finditer(text):
        _push(int(m_.group(1)), int(m_.group(2)), int(m_.group(3)), None)
    for m_ in _RE_DATE_ISO.finditer(text):
        _push(int(m_.group(1)), int(m_.group(3)), int(m_.group(4)), None)
    for m_ in _RE_DATE_EN1.finditer(text):
        month = _MONTH_WORDS.get(m_.group(1).lower())
        if month:
            _push(int(m_.group(3)), month, int(m_.group(2)), None)
    for m_ in _RE_DATE_EN2.finditer(text):
        month = _MONTH_WORDS.get(m_.group(2).lower())
        if month:
            _push(int(m_.group(3)), month, int(m_.group(1)), None)
    for m_ in _RE_DATE_US.finditer(text):
        a, b, y = int(m_.group(1)), int(m_.group(2)), int(m_.group(3))
        if a > 12 >= b:  # 只能是 D/M/YYYY
            _push(y, b, a, "日期形似 D/M/YYYY(日>月),已按 D/M 解析")
        else:
            # 月日都 ≤12 → M/D 与 D/M 都说得通(Reddit 美式惯例取 M/D),
            # 换位即错盘,强制人工确认一次
            _push(y, a, b, "日期按美式 M/D/YYYY 假定解析(月日都≤12 有换位歧义),请复核")
            ambiguous = True
    if len(found) > 1:
        notes.append(f"出现多个日期({','.join(found[:3])}),取第一个,请复核生日是哪个")
        ambiguous = True
    return found, ambiguous


def _in_shichen_window(hour: int, branch: str) -> bool:
    mid = _SHICHEN_MIDPOINT[branch]
    return (hour - mid) % 24 in (0, 1, 23)


def _from_hhmm(m: re.Match, notes: list[str]) -> tuple[str | None, bool]:
    """HH:MM(±am/pm)路径。返回 (time, force_review)。"""
    h, mi = int(m.group(1)), int(m.group(2))
    suffix = (m.group(3) or "").replace(".", "").lower()
    force = False
    if suffix == "pm" and h < 12:
        h += 12
    elif suffix == "am" and h == 12:
        h = 0
    elif not suffix and 1 <= h <= 12:
        # 裸 12h 制(无 am/pm、无中文时段):±12h 真歧义,不静默取 AM
        notes.append(f"时刻 {h}:{mi:02d} 无上下午标记,暂按前半天(AM)解析,请人工确认")
        force = True
    if suffix in ("am", "pm") and h >= 13:
        notes.append(f"时刻 {h}:{mi:02d} 已是 24h 制却带 {suffix},矛盾输入,请复核")
    if not (0 <= h <= 23 and 0 <= mi <= 59):
        notes.append(f"时刻 {h}:{mi:02d} 越界,置空待人工")
        return None, force
    return f"{h:02d}:{mi:02d}", force


def _from_zh(m: re.Match, notes: list[str]) -> tuple[str | None, bool]:
    """中文时段+点(分/半)路径。返回 (time, force_review)。"""
    modifier, h = m.group(1), int(m.group(2))
    minutes = int(m.group(3)) if m.group(3) else 0
    if "半" in m.group(0):
        minutes = 30
    force = False
    if modifier in ("下午", "午后"):
        h = h + 12 if h < 12 else h          # 下午12点 = 12:00(正午惯例)
    elif modifier in ("晚上", "傍晚", "黄昏"):
        h = 0 if h == 12 else h + 12         # 晚上12点 = 00:00(午夜惯例)
    elif modifier in ("中午", "正午"):
        h = h + 12 if h < 11 else h          # 中午11点=11:00,中午1点=13:00
    elif modifier == "凌晨":
        h = 0 if h == 12 else h              # 凌晨12点 = 00:00
    elif modifier in ("上午", "早上"):
        if h == 12:
            h = 0
            notes.append("上午12点按 00:00 解析(罕见写法),请复核")
    else:
        # 无时段词的裸「X点」:±12h 歧义,同裸 12h 制处理
        if 1 <= h <= 12:
            notes.append(f"时刻 {h}点 无上下午时段词,暂按前半天解析,请人工确认")
            force = True
    if not (0 <= h <= 23 and 0 <= minutes <= 59):
        notes.append(f"时刻 {m.group(0)!r} 越界,置空待人工")
        return None, force
    return f"{h:02d}:{minutes:02d}", force


def _extract_time(text: str, notes: list[str]) -> tuple[str | None, bool]:
    """时刻提取。优先级:HH:MM / 中文时段+点(精确) > 时辰中点;
    时辰与精确钟点并存做一致性核对,矛盾强制 review。"""
    shichen_m = _RE_SHICHEN.search(text)
    hhmm_m = _RE_TIME_HHMM.search(text)
    zh_m = _RE_TIME_ZH.search(text)
    time_str: str | None = None
    force = False

    if hhmm_m:
        time_str, force = _from_hhmm(hhmm_m, notes)
    elif zh_m and zh_m.group(2):
        time_str, force = _from_zh(zh_m, notes)
    elif shichen_m:
        branch = shichen_m.group(1)
        hour = _SHICHEN_MIDPOINT[branch]
        time_str = f"{hour:02d}:00"
        notes.append(f"只给时辰(取中点 {time_str},与 App 表单同口径)")

    if time_str and shichen_m:
        hour = int(time_str[:2])
        if not _in_shichen_window(hour, shichen_m.group(1)):
            notes.append(
                f"时辰{shichen_m.group(1)}时与钟点 {time_str} 矛盾,请人工判断")
            force = True

    if time_str is None:
        low = text.lower()
        if any(w in low or w in text for w in _FUZZY_HOUR_WORDS):
            notes.append("只给模糊时段词(天刚亮/傍晚等),不确定,留人工")

    if time_str and int(time_str[:2]) in (23, 0):
        notes.append("落在子时边界(产品口径 23:00 换日,引擎自动处理,确认日期无误即可)")
    return time_str, force


def _extract_gender(text: str, notes: list[str]) -> str | None:
    """男女词共现(含指他人语境)→ None 留人工,不先到先得。"""
    low = text.lower()
    female = "女" in text or bool(re.search(r"\b(female|woman|girl)\b", low))
    male = "男" in text or bool(re.search(r"\b(male|man|guy|boy)\b", low))
    if female and male:
        notes.append("男女词共现(可能指他人),性别需人工确认")
        return None
    if female:
        return "female"
    if male:
        return "male"
    return None


def deterministic_parse(block: str) -> dict[str, Any]:
    """确定性提取。返回 rec(字段可缺)+ note + force_review 标记。

    只提取「原文明确写了且无歧义」的;拿不准的宁可 None + note + review
    (force_review=True 时即使四要素齐也压回 review,由 finalize 落实)。
    question 只认显式标记行;自然语言问句交给 LLM 兜底或人工。
    """
    notes: list[str] = []
    force = False
    rec: dict[str, Any] = {"raw_text": block}

    m = _RE_USERNAME.search(block)
    rec["username"] = m.group(1) if m else ""

    dates, d_ambiguous = _collect_dates(block, notes)
    rec["birth_date"] = dates[0] if dates else None
    if d_ambiguous:
        force = True

    time_str, t_force = _extract_time(block, notes)
    rec["birth_time"] = time_str
    force = force or t_force

    rec["gender"] = _extract_gender(block, notes)

    qm = re.search(
        r"(?:^|\n|\s)(?:question|问题|想问|帮我问)\s*(?:：|:)\s*(.+)",
        block, flags=re.I)
    if qm:
        rec["question"] = qm.group(1).strip()[:300]

    if _LUNAR_MARKERS.search(block):
        notes.append("原文疑似农历日期,本工具不自动换算——人工换算公历后回填")
        force = True

    rec["note"] = ";".join(notes)
    rec["force_review"] = force
    return rec


def missing_critical(rec: dict[str, Any]) -> list[str]:
    """判定还缺哪些必要字段(城市经度在 resolve_city 之后才有)。"""
    missing = []
    for k in ("birth_date", "birth_time", "gender", "question"):
        if not rec.get(k):
            missing.append(k)
    return missing


# ---------- 城市与时区 ----------

def resolve_city(city_name: str) -> tuple[dict[str, Any] | None, list[str]]:
    """城市名 → (记录, 候选清单)。

    精确命中(中文名相等/英文名忽略大小写)且唯一才自动采用;
    多个精确同名城(如 Portland×16,横跨时区)降级为候选留人工——
    选错城市 = 整盘时区错,宁可留人工。tz_offset 由 finalize_record 补。

    Returns:
        ({"city", "city_tz", "longitude"} | None, 候选描述列表)
    """
    name = (city_name or "").strip()
    if not name:
        return None, []
    if not _CITY_DB_PATH.exists():
        raise FileNotFoundError(
            f"城市库缺失:{_CITY_DB_PATH}(构建方式见 tools/build_city_db.py)")
    with closing(sqlite3.connect(f"file:{_CITY_DB_PATH}?mode=ro", uri=True)) as conn:
        conn.row_factory = sqlite3.Row
        exact = conn.execute(
            """SELECT name_zh, name, lng, tz, country, admin1 FROM cities
               WHERE name_zh = ? OR name = ? COLLATE NOCASE
               ORDER BY population DESC LIMIT 6""", (name, name)).fetchall()
        if len(exact) == 1:
            r = exact[0]
            return {"city": r["name_zh"], "city_tz": r["tz"],
                    "longitude": r["lng"]}, []
        if len(exact) > 1:
            return None, [_city_label(r) for r in exact]
        fuzzy = conn.execute(
            """SELECT name_zh, name, lng, tz, country, admin1 FROM cities
               WHERE name_zh LIKE ? OR name LIKE ?
               ORDER BY population DESC LIMIT 5""", (f"%{name}%", f"%{name}%"),
        ).fetchall()
        return None, [_city_label(r) for r in fuzzy]


def _city_label(r: sqlite3.Row) -> str:
    return (f"{r['name_zh']}({r['name']}, {r['country']} {r['admin1'] or ''}, "
            f"{r['tz']})")


def tz_offset_hours(tz_name: str, naive_dt: datetime) -> float:
    """出生时刻(当地钟面)的真实 UTC 偏移,与 /geo/tz_offset 同规则
    (IANA 历史规则,含 1986-1991 中国夏令时;DST fold 歧义取 fold=0)。"""
    aware = naive_dt.replace(tzinfo=ZoneInfo(tz_name))
    return aware.utcoffset().total_seconds() / 3600


# ---------- 归一化(人工修正入口共用) ----------

def normalize_time(value: str | None) -> tuple[str | None, str | None]:
    """HH:MM 归一化(9:30 → 09:30);不合法显式返回原因。"""
    if not value:
        return None, None
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", value.strip())
    if not m:
        return None, f"时间 {value!r} 非 HH:MM 格式"
    h, mi = int(m.group(1)), int(m.group(2))
    if not (0 <= h <= 23 and 0 <= mi <= 59):
        return None, f"时间 {value!r} 越界"
    return f"{h:02d}:{mi:02d}", None


def normalize_date(value: str | None) -> tuple[str | None, str | None]:
    """日期归一化 + 历法校验;不合法显式返回原因。"""
    if not value:
        return None, None
    m = re.fullmatch(r"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})", value.strip())
    if not m:
        return None, f"日期 {value!r} 非 YYYY-MM-DD 格式"
    iso = _valid_ymd(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    if iso is None:
        return None, f"日期 {value!r} 历法越界"
    return iso, None


def finalize_record(rec: dict[str, Any]) -> dict[str, Any]:
    """解析收口:归一化 + 补 tz_offset + 判状态。

    ready 的完整条件:四要素齐 + 经度在 + tz_offset 可算 + 无 force_review
    标记。note 组成 = 解析 note + 当次缺失清单;重复 finalize 时先剥掉
    上次追加的「缺:…」段再重组,不叠加。
    """
    parse_note = rec.get("note") or ""
    notes = [s for s in parse_note.split(";") if s and not s.startswith("缺:")]

    nd, err = normalize_date(rec.get("birth_date"))
    if err:
        notes.append(err)
    rec["birth_date"] = nd
    nt, err = normalize_time(rec.get("birth_time"))
    if err:
        notes.append(err)
    rec["birth_time"] = nt

    if rec.get("city_tz") and rec["birth_date"] and rec["birth_time"]:
        naive = datetime.fromisoformat(f"{rec['birth_date']}T{rec['birth_time']}:00")
        computed = tz_offset_hours(rec["city_tz"], naive)
        prev = rec.get("tz_offset")
        # 覆盖操作者手填值时留痕(不静默吞人工输入;IANA 历史规则优先,
        # 含 1986-1991 中国夏令时;DST fold 取 fold=0)
        if prev is not None and abs(float(prev) - computed) >= 0.01:
            notes.append(f"tz_offset 按 {rec['city_tz']} 重算为 {computed:g}"
                         f"(原填 {float(prev):g})")
        rec["tz_offset"] = computed

    missing = missing_critical(rec)
    if rec.get("longitude") is None:
        missing.append("city(经度)")
    if rec.get("tz_offset") is None:
        missing.append("tz_offset")
    if missing:
        notes.append("缺:" + ",".join(dict.fromkeys(missing)))
    if rec.get("force_review") or missing:
        rec["status"] = "review"
    else:
        rec["status"] = "ready"
    rec["note"] = ";".join(n for n in notes if n)
    return rec


def birth_datetime(order: sqlite3.Row) -> datetime:
    """订单行 → 带时区 birth datetime(runner 与结果页复用,与
    main._parse_birth_from_form 同一口径,偏移支持半时区 float)。
    缺字段显式抛 ValueError。"""
    if not order["birth_date"] or not order["birth_time"] or order["tz_offset"] is None:
        raise ValueError(
            f"订单 #{order['id']} 出生字段不全(date/time/tz_offset),"
            "不能用于排盘——请先在接单台修正")
    naive = datetime.fromisoformat(f"{order['birth_date']}T{order['birth_time']}:00")
    return naive.replace(tzinfo=timezone(timedelta(hours=float(order["tz_offset"]))))
