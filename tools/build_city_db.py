#!/usr/bin/env python3
"""城市数据库构建管线 — GeoNames dump → iOS cities.sqlite + manifest.json。

Parent 设计事实源: docs/城市搜索设计决策.md(Q2/Q3/Q6/Q7/Q9)
Slice 事实源:     docs/城市搜索-slices/S01-城市数据库构建管线.md

用法:
    python3 tools/build_city_db.py                    # cities1000(默认)
    python3 tools/build_city_db.py --dataset cities5000

产物:
    ios/QiCompass/QiCompass/Resources/cities.sqlite   (进 git,Xcode bundle 资源)
    tools/city-data/manifest.json                     (进 git)
    tools/city-data/cache/                            (GeoNames 原始 dump,gitignore)

守护栏(决策 Q9):动了本脚本 / curated_aliases.tsv / cities.sqlite 之后,
必须跑 `python3 tools/check_city_db.py` 且 PASS。

确定性红线:同一 dump + 同一脚本 → byte-identical 的 sqlite 与 manifest。
因此 manifest 只记 dump 自带的 moddate,绝不写构建时刻。

体积门槛(决策 Q9):sqlite > 25MB → 退出码 2 并停止,等用户拍板切 cities5000。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import socket
import sqlite3
import sys
import time
import unicodedata
import urllib.request
import zipfile
from pathlib import Path
from typing import IO, Iterable

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = REPO_ROOT / "tools" / "city-data" / "cache"
MANIFEST_PATH = REPO_ROOT / "tools" / "city-data" / "manifest.json"
ALIASES_TSV = REPO_ROOT / "tools" / "city-data" / "curated_aliases.tsv"
DEFAULT_DB = REPO_ROOT / "ios" / "QiCompass" / "QiCompass" / "Resources" / "cities.sqlite"

GEONAMES = "https://download.geonames.org/export/dump"
DATASETS = ("cities1000", "cities5000")
SIZE_BUDGET_BYTES = 25 * 1024 * 1024

# 国家中文名:CLDR 原始下载不可达,改用静态内嵌 countries_zh.tsv(译名对齐 CLDR zh 习惯)
COUNTRIES_TSV = REPO_ROOT / "tools" / "city-data" / "countries_zh.tsv"

SCHEMA_VERSION = 1

# 搜索键类型码(小整数省空间;iOS 侧排序不依赖此列,仅诊断用)
KEY_ZH, KEY_ZH_HANT, KEY_EN, KEY_PINYIN, KEY_INITIALS, KEY_ALIAS = range(6)
KEY_TYPE_NAMES = {
    KEY_ZH: "zh",
    KEY_ZH_HANT: "zh_hant",
    KEY_EN: "en",
    KEY_PINYIN: "pinyin",
    KEY_INITIALS: "initials",
    KEY_ALIAS: "alias",
}


# ---------------------------------------------------------------------------
# 归一化(查询侧 iOS 必须复刻同规则,见 S03;golden queries S06 兜底防漂移)
# ---------------------------------------------------------------------------

def normalize_key(s: str) -> str:
    """NFC → NFKD → 去组合变音符 → casefold → 去分隔符。

    - ü→u / é→e(英文键盘打外国名可命中)
    - 分隔符(空格/连字符/撇号/点)全部移除:xi'an 与 xian 等价
    """
    s = unicodedata.normalize("NFC", s)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = s.casefold()
    return re.sub(r"[\W_]+", "", s, flags=re.UNICODE)


# ---------------------------------------------------------------------------
# 下载(缓存优先,幂等)
# ---------------------------------------------------------------------------

def download_cached(url: str, dest: Path) -> Path:
    if dest.exists() and dest.stat().st_size > 0:
        print(f"[cache] {dest.name} 已存在,跳过下载")
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")

    def report(blocks: int, block_size: int, total: int) -> None:
        done = blocks * block_size
        if total > 0:
            mb = done / 1e6
            print(f"\r[down ] {dest.name}: {mb:8.1f} MB", end="", flush=True)

    print(f"[down ] {url}")
    try:
        urllib.request.urlretrieve(url, tmp, reporthook=report)
    finally:
        print()
    tmp.rename(dest)
    return dest


# ---------------------------------------------------------------------------
# GeoNames dump 解析
# ---------------------------------------------------------------------------

class City:
    __slots__ = (
        "gid", "name", "ascii", "lat", "lon", "cc", "admin1", "pop", "tz", "moddate",
        "name_zh", "zh_short", "zh_names", "hant_names", "en_names", "pinyin_keys",
    )

    def __init__(self, cols: list[str]):
        # GeoNames 列序:0 gid / 1 name / 2 asciiname / 6 fclass / 7 fcode / 8 cc
        # 10 admin1 / 14 population / 17 timezone / 18 modification date
        self.gid = int(cols[0])
        self.name = cols[1]
        self.ascii = cols[2]
        self.lat = cols[4]
        self.lon = cols[5]
        self.cc = cols[8]
        self.admin1 = cols[10]
        pop = cols[14]
        self.pop = int(pop) if pop not in ("", "0") else 0
        self.tz = cols[17]
        self.moddate = cols[18]
        # 别名由 alternateNamesV2 pass 填充
        self.name_zh: str | None = None
        self.zh_short = False  # name_zh 是否已是 short 名(北京市 vs 北京)
        self.zh_names: list[str] = []
        self.hant_names: list[str] = []
        self.en_names: list[str] = []
        self.pinyin_keys: list[tuple[str, int]] = []  # (归一化键, KEY_PINYIN|KEY_INITIALS)


# V2 实测语言码:简中是 zh-CN(不是 zh!),繁中 zh-Hant/zh-TW/zh-HK
LANGS_SIMP = ("zh", "zh-CN", "zh-Hans")
LANGS_TRAD = ("zh-Hant", "zh-TW", "zh-HK")


def _is_official_city_form(name: str) -> bool:
    """中文行政正式形态(市/县结尾)。GeoNames 有把镇级 zh 挂到市条目的脏数据
    (昆山 → 玉山),市/县后缀优先可纠偏。"""
    return name.endswith(("市", "县"))


def zip_entry_name(zf: zipfile.ZipFile, prefer_stem: str) -> str:
    """zip 里可能有多个文件(alternateNamesV2.zip 还含 iso-languagecodes.txt),
    必须按名字选目标文件,不能拿 namelist()[0]。"""
    names = zf.namelist()
    for n in names:
        if Path(n).stem == prefer_stem:
            return n
    others = [n for n in names if n.endswith(".txt") and "languagecodes" not in n]
    if len(others) == 1:
        return others[0]
    raise SystemExit(f"错误: {zf.filename} 里找不到目标文件 {prefer_stem}(实际:{names})")


def iter_dump_lines(path: Path, prefer_stem: str) -> Iterable[list[str]]:
    with zipfile.ZipFile(path) as zf:
        with zf.open(zip_entry_name(zf, prefer_stem)) as fh:
            for raw in io_text(fh):
                line = raw.rstrip("\n").rstrip("\r")
                if line:
                    yield line.split("\t")


def io_text(fh: IO[bytes]) -> Iterable[str]:
    """逐行严格 UTF-8 解码 — 坏字节显式报错,绝不 replace 成 U+FFFD 静默入库。"""
    for raw in fh:
        try:
            yield raw.decode("utf-8")
        except UnicodeDecodeError as e:
            name = getattr(fh, "name", "?")
            raise SystemExit(f"错误: {name} 含非 UTF-8 字节 — {e}") from e


MUNICIPALITY_ADMIN1_EN = {"Beijing", "Shanghai", "Tianjin", "Chongqing"}


def load_cities(dataset: str, path: Path, muni_admin1_codes: set[str]) -> dict[int, City]:
    cities: dict[int, City] = {}
    dropped = 0
    for cols in iter_dump_lines(path, dataset):
        if len(cols) < 19:
            # 红线:字段缺失报错退出,不静默跳行(数据损坏要让构建停下来)
            preview = "\t".join(cols)[:80]
            raise SystemExit(f"错误: {dataset} dump 畸形行列数 {len(cols)} < 19: {preview!r}")
        # 决策 Q3:市辖区不单列。
        # 1) 中国区 PPLX(城区片区,如浦西/罗湖)整行滤掉;海外 PPLX
        #    (如 Brooklyn)是有效出生地语义,保留
        # 2) 直辖市下的 PPLA4/PPLA5 行即「区」(闵行/嘉定/浦东…),
        #    同样滤掉,由 curated 区县别名(海淀→北京)承接
        if cols[8] == "CN" and (
            cols[7] == "PPLX"
            or (cols[10] in muni_admin1_codes and cols[7] in ("PPLA4", "PPLA5"))
        ):
            dropped += 1
            continue
        c = City(cols)
        cities[c.gid] = c
    print(f"[load ] {dataset}: {len(cities)} 城市(滤掉 CN 市辖区/片区 {dropped} 行)")
    return cities


def apply_alternate_names(path: Path, cities: dict[int, City], admin1_gids: dict[int, str]) -> tuple[dict[int, str], dict[int, str]]:
    """流式扫 alternateNamesV2(约 1900 万行),只留 zh / zh-Hant / en。

    返回 (admin1_gid → zh名, admin1_gid → hant名)。
    name_zh 选择规则(流式单遍、确定性,行按 alternateNameId 升序):
      1. historic 跳过;colloquial 只进搜索键不当显示名
      2. 首个非 colloquial zh 先占位
      3. 之后出现 isShortName=1 且当前占位不是 short → 覆盖(北京市 → 北京)
    """
    admin1_zh: dict[int, str] = {}
    admin1_hant: dict[int, str] = {}
    kept = 0
    with zipfile.ZipFile(path) as zf:
        with zf.open(zip_entry_name(zf, "alternateNamesV2")) as fh:
            for line in io_text(fh):
                cols = line.rstrip("\n").rstrip("\r").split("\t")
                if len(cols) < 8:
                    raise SystemExit(
                        f"错误: alternateNamesV2 畸形行列数 {len(cols)} < 8: {line.rstrip()[:80]!r}"
                    )
                lang = cols[2]
                is_simp = lang in LANGS_SIMP
                is_trad = lang in LANGS_TRAD
                if not (is_simp or is_trad or lang == "en"):
                    continue
                gid = int(cols[1])
                name = cols[3]
                is_short, is_colloq, is_hist = cols[5], cols[6], cols[7]
                if is_hist == "1":
                    continue
                city = cities.get(gid)
                if city is None:
                    # 省级行政区(admin1)的别名:short 优先,同 apply 同规则;
                    # colloquial 与城市分支一致,不当显示名
                    if gid in admin1_gids and lang != "en" and is_colloq != "1":
                        target = admin1_zh if is_simp else admin1_hant
                        if gid not in target or is_short == "1":
                            target[gid] = name
                    continue
                if is_colloq == "1":
                    # 口语别名只进搜索键(三藩市之类由 curated 兜底更稳)
                    if is_simp:
                        city.zh_names.append(name)
                    elif is_trad:
                        city.hant_names.append(name)
                    kept += 1
                    continue
                if is_simp:
                    city.zh_names.append(name)
                    # name_zh 选择优先级:short(北京)> 市县后缀正式形(昆山市)> 首条
                    if city.name_zh is None:
                        city.name_zh = name
                        city.zh_short = is_short == "1"
                    elif is_short == "1" and not city.zh_short:
                        city.name_zh = name
                        city.zh_short = True
                    elif (not city.zh_short
                          and not _is_official_city_form(city.name_zh)
                          and _is_official_city_form(name)):
                        city.name_zh = name
                elif is_trad:
                    city.hant_names.append(name)
                else:
                    city.en_names.append(name)
                kept += 1
    print(f"[load ] alternateNamesV2: 命中 {kept} 条(简中/繁中/en)")
    return admin1_zh, admin1_hant


def load_admin1(path: Path) -> tuple[dict[str, tuple[str, int]], dict[int, str]]:
    """admin1CodesASCII.txt → (code → (name, gid), gid → code)"""
    by_code: dict[str, tuple[str, int]] = {}
    by_gid: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        cols = line.split("\t")
        if len(cols) < 4:
            raise SystemExit(
                f"错误: admin1CodesASCII 畸形行列数 {len(cols)} < 4: {line[:80]!r}"
            )
        code, name, _ascii, gid = cols[0], cols[1], cols[2], int(cols[3])
        by_code[code] = (name, gid)
        by_gid[gid] = code
    print(f"[load ] admin1: {len(by_code)} 条")
    return by_code, by_gid


def load_countries_tsv() -> tuple[dict[str, str], dict[str, str]]:
    """国家码 → (中文名表, 英文名表)。静态内嵌(决策 Q7:译名对齐 CLDR zh 习惯)。"""
    zh: dict[str, str] = {}
    en: dict[str, str] = {}
    if not COUNTRIES_TSV.exists():
        print(f"错误: 缺少 {COUNTRIES_TSV}", file=sys.stderr)
        raise SystemExit(1)
    for ln, line in enumerate(COUNTRIES_TSV.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = [x.strip() for x in line.split("\t")]
        if len(cols) != 3:
            print(f"错误: countries_zh.tsv:{ln} 列数 != 3 — {line}", file=sys.stderr)
            raise SystemExit(1)
        cc, zh_name, en_name = cols
        zh[cc] = zh_name
        en[cc] = en_name
    print(f"[load ] countries_zh.tsv: {len(zh)} 条")
    return zh, en


# ---------------------------------------------------------------------------
# 拼音(pypinyin,构建期已获批)
# ---------------------------------------------------------------------------

def make_pinyin_keys(cities: dict[int, City]) -> None:
    try:
        from pypinyin import Style, lazy_pinyin
    except ImportError:
        print("错误: 缺少构建期依赖 pypinyin(pip3 install pypinyin)", file=sys.stderr)
        raise SystemExit(1)

    for c in cities.values():
        seen: set[str] = set()
        sources = [n for n in (c.name_zh, *c.zh_names) if n]
        for src in sources:
            if not any("\u4e00" <= ch <= "\u9fff" for ch in src):
                continue
            full = "".join(lazy_pinyin(src, style=Style.NORMAL, errors="ignore"))
            initials = "".join(lazy_pinyin(src, style=Style.FIRST_LETTER, errors="ignore"))
            for p, t in ((full, KEY_PINYIN), (initials, KEY_INITIALS)):
                p = normalize_key(p)
                if p and p not in seen:
                    seen.add(p)
                    c.pinyin_keys.append((p, t))
    print("[pinyin] 生成完毕")


# ---------------------------------------------------------------------------
# curated 别名
# ---------------------------------------------------------------------------

def load_curated_aliases(cities: dict[int, City]) -> dict[int, tuple[list[str], str | None]]:
    """curated_aliases.tsv: alias <TAB> GeoNames主名 <TAB> 国家码 [<TAB> 中文显示名]。
    按主名+国家码解析到 geoname_id;解析失败必须报错(错误显式传播)。
    第 4 列可选:该城 GeoNames 缺 zh 名时作为 name_zh 兜底(常熟/慈溪等)。"""
    if not ALIASES_TSV.exists():
        print(f"错误: 缺少 {ALIASES_TSV}", file=sys.stderr)
        raise SystemExit(1)
    name_index: dict[tuple[str, str], int] = {}
    for c in cities.values():
        key = (c.name, c.cc)
        # 同名同城(极少):保留人口高的那个,确定性
        if key not in name_index or c.pop > cities[name_index[key]].pop:
            name_index[key] = c.gid

    out: dict[int, tuple[list[str], str | None]] = {}
    unresolved = []
    for ln, line in enumerate(ALIASES_TSV.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = [x.strip() for x in line.split("\t")]
        if len(cols) not in (3, 4):
            unresolved.append((ln, line, "列数 != 3/4"))
            continue
        alias, target, cc = cols[0], cols[1], cols[2]
        zh_display = cols[3] if len(cols) == 4 else None
        gid = name_index.get((target, cc))
        if gid is None:
            unresolved.append((ln, line, f"找不到目标城市 {target} ({cc})"))
            continue
        aliases, zh = out.get(gid, ([], None))
        aliases.append(alias)
        out[gid] = (aliases, zh or zh_display)
    if unresolved:
        for ln, line, why in unresolved:
            print(f"错误: curated_aliases.tsv:{ln} 「{line}」— {why}", file=sys.stderr)
        raise SystemExit(1)
    total = sum(len(v[0]) for v in out.values())
    print(f"[alias] curated: {total} 条 → {len(out)} 城市")
    return out


# ---------------------------------------------------------------------------
# SQLite 产出(确定性:按 geoname_id 升序写入,键按 (gid, key) 排序,收尾 VACUUM)
# ---------------------------------------------------------------------------

def build_sqlite(cities: dict[int, City], out_path: Path,
                 admin1_by_code: dict[str, tuple[str, int]],
                 admin1_zh: dict[int, str], admin1_hant: dict[int, str],
                 countries_zh: dict[str, str], countries_en: dict[str, str],
                 curated: dict[int, tuple[list[str], str | None]]) -> dict:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()
    conn = sqlite3.connect(out_path)
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("PRAGMA page_size=4096")
    cur = conn.cursor()
    cur.executescript(
        """
        CREATE TABLE cities (
            geoname_id INTEGER PRIMARY KEY,
            name       TEXT NOT NULL,
            name_zh    TEXT,
            name_en    TEXT NOT NULL,
            country_code TEXT NOT NULL,
            admin1_code TEXT,
            admin1_name TEXT,
            lat INTEGER NOT NULL,
            lon INTEGER NOT NULL,
            tz_id INTEGER NOT NULL,
            is_cn INTEGER NOT NULL,
            population INTEGER NOT NULL
        );
        CREATE TABLE timezones (
            tz_id INTEGER PRIMARY KEY,
            iana_name TEXT NOT NULL UNIQUE
        );
        CREATE TABLE countries (
            country_code TEXT PRIMARY KEY,
            name_zh TEXT NOT NULL,
            name_en TEXT NOT NULL
        );
        CREATE TABLE search_keys (
            key TEXT NOT NULL,
            geoname_id INTEGER NOT NULL,
            key_type INTEGER NOT NULL
        );
        CREATE INDEX idx_keys_key ON search_keys(key COLLATE NOCASE);
        """
    )

    # 时区外键:按 iana_name 排序分配 tz_id(确定性)
    tz_names = sorted({c.tz for c in cities.values() if c.tz})
    tz_id_of = {n: i + 1 for i, n in enumerate(tz_names)}
    cur.executemany("INSERT INTO timezones VALUES (?, ?)", list(enumerate(tz_names, 1)))

    # 国家表:CLDR zh/en;GeoNames 里出现但 CLDR 缺的码 → 显式报错(不许静默空名)
    used_cc = sorted({c.cc for c in cities.values() if c.cc})
    missing_cc = [cc for cc in used_cc if cc not in countries_zh or cc not in countries_en]
    if missing_cc:
        print(f"错误: 以下国家码缺 CLDR 中文名: {missing_cc}", file=sys.stderr)
        raise SystemExit(1)
    cur.executemany(
        "INSERT INTO countries VALUES (?, ?, ?)",
        [(cc, countries_zh[cc], countries_en[cc]) for cc in used_cc],
    )

    # 必填字段校验:空 cc / 空 tz 显式报错,不静默丢行(错误显式传播)
    invalid = [c for c in cities.values() if not c.cc or not c.tz]
    if invalid:
        examples = [(c.gid, c.name, repr(c.cc), repr(c.tz)) for c in invalid[:5]]
        print(f"错误: {len(invalid)} 个城市缺 country/timezone,示例 {examples}", file=sys.stderr)
        raise SystemExit(1)

    rows = []
    key_rows = []
    for c in sorted(cities.values(), key=lambda x: x.gid):
        admin1_display = None
        if c.admin1 and f"{c.cc}.{c.admin1}" in admin1_by_code:
            _name, gid = admin1_by_code[f"{c.cc}.{c.admin1}"]
            admin1_display = admin1_zh.get(gid) or admin1_hant.get(gid) or _name
        rows.append((
            c.gid, c.name, c.name_zh, c.name, c.cc, c.admin1 or None, admin1_display,
            round(float(c.lat) * 10000), round(float(c.lon) * 10000),
            tz_id_of[c.tz], 1 if c.cc == "CN" else 0, c.pop,
        ))
        # 搜索键:同键先到先得,生成顺序固定 → 确定性
        keys: dict[str, int] = {}

        def add(k: str, t: int) -> None:
            nk = normalize_key(k)
            if nk and nk not in keys:
                keys[nk] = t

        for n in c.zh_names:
            add(n, KEY_ZH)
        for n in c.hant_names:
            add(n, KEY_ZH_HANT)
        add(c.name, KEY_EN)
        if c.ascii and c.ascii != c.name:
            add(c.ascii, KEY_EN)
        for n in c.en_names:
            add(n, KEY_EN)
        for p, t in c.pinyin_keys:
            add(p, t)
        for a in curated.get(c.gid, ([], None))[0]:
            add(a, KEY_ALIAS)
        key_rows.extend((k, c.gid, t) for k, t in sorted(keys.items()))

    cur.executemany("INSERT INTO cities VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    cur.executemany("INSERT INTO search_keys VALUES (?,?,?)", key_rows)
    conn.commit()
    cur.execute("VACUUM")
    conn.close()

    return {
        "cities": len(rows),
        "search_keys": len(key_rows),
        "timezones": len(tz_names),
        "countries": len(used_cc),
    }


# ---------------------------------------------------------------------------
# manifest(只含确定性信息,无构建时刻)
# ---------------------------------------------------------------------------

def write_manifest(dataset: str, db_path: Path, stats: dict, cities: dict[int, City],
                   alias_count: int, pypinyin_version: str) -> None:
    sha = hashlib.sha256(db_path.read_bytes()).hexdigest()
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "dataset": dataset,
        "pypinyin_version": pypinyin_version,
        "cities": stats["cities"],
        "search_keys": stats["search_keys"],
        "timezones": stats["timezones"],
        "countries": stats["countries"],
        "curated_aliases": alias_count,
        "geonames_moddate_max": max((c.moddate for c in cities.values()), default=""),
        "sqlite_sha256": sha,
        "sqlite_bytes": db_path.stat().st_size,
    }
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", choices=DATASETS, default="cities1000")
    parser.add_argument("--out", type=Path, default=DEFAULT_DB)
    args = parser.parse_args()

    print(f"== 城市数据库构建(dataset={args.dataset})==")
    t0 = time.perf_counter()
    socket.setdefaulttimeout(120)  # urlretrieve 无超时参数,全局兜底防挂起
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    cities_zip = download_cached(f"{GEONAMES}/{args.dataset}.zip", CACHE_DIR / f"{args.dataset}.zip")
    altnames_zip = download_cached(f"{GEONAMES}/alternateNamesV2.zip", CACHE_DIR / "alternateNamesV2.zip")
    admin1_txt = download_cached(f"{GEONAMES}/admin1CodesASCII.txt", CACHE_DIR / "admin1CodesASCII.txt")
    countries_zh, countries_en = load_countries_tsv()

    # admin1 先于 cities 载入:直辖市码用于 load_cities 的区级行过滤
    admin1_by_code, admin1_by_gid = load_admin1(admin1_txt)
    muni_admin1_codes = {code.split(".", 1)[1] for code, (name, _gid) in admin1_by_code.items()
                         if code.startswith("CN.") and name in MUNICIPALITY_ADMIN1_EN}
    cities = load_cities(args.dataset, cities_zip, muni_admin1_codes)
    admin1_zh, admin1_hant = apply_alternate_names(altnames_zip, cities, admin1_by_gid)
    curated = load_curated_aliases(cities)
    # curated 第 4 列兜底:GeoNames 缺 zh 的城(常熟/慈溪…)补 name_zh,
    # 须在拼音生成前应用,让拼音键基于中文生成
    fixed_zh = 0
    for gid, (_aliases, zh) in curated.items():
        city = cities[gid]
        if zh and city.name_zh is None:
            city.name_zh = zh
            city.zh_names.append(zh)
            fixed_zh += 1
    if fixed_zh:
        print(f"[alias] curated 兜底中文显示名: {fixed_zh} 城")
    make_pinyin_keys(cities)
    # 构建参数入 manifest:拼音键随 pypinyin 版本可变,不记版本则 hash 漂移无法归因
    from importlib.metadata import version as pkg_version
    pypinyin_version = pkg_version("pypinyin")

    stats = build_sqlite(
        cities, args.out, admin1_by_code, admin1_zh, admin1_hant,
        countries_zh, countries_en, curated,
    )
    alias_count = sum(len(v[0]) for v in curated.values())
    write_manifest(args.dataset, args.out, stats, cities, alias_count, pypinyin_version)

    size = args.out.stat().st_size
    print(
        f"[done ] {args.out}\n"
        f"        城市 {stats['cities']} / 搜索键 {stats['search_keys']} / "
        f"时区 {stats['timezones']} / 国家 {stats['countries']} / curated别名 {alias_count}\n"
        f"        体积 {size / 1e6:.1f} MB(预算 25.0 MB)/ 构建耗时 {time.perf_counter() - t0:.1f}s"
    )
    if size > SIZE_BUDGET_BYTES:
        print(
            "!! 超出 25MB 预算 — 按决策 Q9 停止,等用户拍板是否切 --dataset cities5000",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
