#!/usr/bin/env python3
"""构建 KnowFate 官网 Web 字体子集(woff2)—— S01。

来源:
  中文:复用 iOS 已提交的 QiSongti-Regular.otf(SC)/ QiSongtiTC-Regular.otf(TC)
       (思源宋体子集,tools/build_songti_fonts.py 的产物),按站点实际用字二次子集,只读不改。
  英文标题:Newsreader(OFL 1.1),google/fonts commit 8b0a1d0f5983 下载留档于
       tools/site-fonts-src/(SHA256 校验,防输入漂移破坏确定性);instancer 钉 wght,
       **保留 opsz 轴**,浏览器 font-optical-sizing:auto 与设计稿(Google Fonts 可变版)表现一致。

输出(site/public/fonts/,全部进 git,构建机无需 Python 环境):
  knowfate-sc.woff2          family "QiSongti Web"    — en 页面 .zh 元素
  knowfate-tc.woff2          family "QiSongti Web TC" — zh-hant 页面(html lang="zh-Hant" 整页换用)
  newsreader-400.woff2       family "Newsreader" 400(全站唯一 preload)
  newsreader-300.woff2       300
  newsreader-italic-300.woff2  italic 300

字表(中文,规格 S01 #4 + §6「按页面实际用字做子集」,按语言腿拆分):
  SC = en 页面产物扫描 CJK ∪ 品牌字 ∪ 天干点缀 ∪ 日期变字(节气名/干支,
       2026-11-28:产物只含构建当天的值,随日期变化的字从 calendar.json 整体收);
  TC = zh-hant 页面 + 共享文件扫描 CJK ∪ 术语表全部 CJK ∪ 品牌字(繁)。
  硬性要求字符缺失 → FAIL(错误显式传播;TC 腿沿用 build_songti_fonts 的 hant_subset 口径:
  Big5 外字符多为简体,由 SC 腿渲染,不算 TC 缺字)。

确定性:同输入 → byte-identical(构建时双跑比对 SHA256,不一致即 FAIL)。

用法(仓库根):
  python3 tools/build_site_fonts.py            # 构建并写入 site/public/fonts + 自检
  python3 tools/build_site_fonts.py --verify   # 只校验已提交产物(守护栏:动站点内容后必跑)
依赖:fontTools ≥ 4.39(instancer)+ brotli(woff2 压缩;2026-11-25 用户批准)。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

REPO = Path(__file__).resolve().parent.parent
SITE = REPO / "site"
IOS_RESOURCES = REPO / "ios" / "QiCompass" / "QiCompass" / "Resources"
SC_SOURCE = IOS_RESOURCES / "QiSongti-Regular.otf"
TC_SOURCE = IOS_RESOURCES / "QiSongtiTC-Regular.otf"
NEWSREADER_DIR = REPO / "tools" / "site-fonts-src"
NEWSREADER_VAR = NEWSREADER_DIR / "Newsreader-var.ttf"
NEWSREADER_ITALIC_VAR = NEWSREADER_DIR / "Newsreader-Italic-var.ttf"
TERM_TRANSLATIONS = REPO / "backend" / "app" / "engine" / "term_translations.py"
TERMS_JSON = SITE / "src" / "data" / "terms.json"

FONTS_OUT = SITE / "public" / "fonts"

FAMILY_SC = "QiSongti Web"
FAMILY_TC = "QiSongti Web TC"
FAMILY_NR = "Newsreader"

# 渲染层可能用到的中文标点/符号(区间外逐个补;Web 版比 iOS 精简)
WEB_SYMBOLS = "·—–…‘’“”‹›«»※「」『』《》〈〉〇°×÷±↑↓←→"

# Newsreader 源 SHA256(与 tools/site-fonts-src/README.md 一致;换源须两处同改)
NEWSREADER_SHA256 = {
    NEWSREADER_VAR.name: "8a08d13f8a6c0d51be379a60af84f945f65369a67e509ee3c3bdcc421254d7c1",
    NEWSREADER_ITALIC_VAR.name: "796668611f80b64d5adf182fde3b6f29ed83b4e7cbec7b96937e84ac01364792",
}

# Newsreader 实例:(输出文件名, 源文件, wght, style);style 用 OS/2 nameID 2 惯例写法
NEWSREADER_INSTANCES = [
    ("newsreader-400.woff2", NEWSREADER_VAR, 400, "Regular"),
    ("newsreader-300.woff2", NEWSREADER_VAR, 300, "Regular"),
    ("newsreader-italic-300.woff2", NEWSREADER_ITALIC_VAR, 300, "Italic"),
]

# Newsreader Latin 子集:ASCII + Latin-1 Supplement + 常用排版标点
NR_UNICODES = (
    set(range(0x20, 0x7F))
    | set(range(0xA0, 0x100))
    | {0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2039, 0x203A, 0x2022, 0x00D7, 0x00F7}
)

SCAN_EXTS = {".astro", ".ts", ".tsx", ".js", ".mjs", ".css", ".html", ".json", ".md", ".mdx", ".txt", ".xml", ".svg"}

BIG5_ONLY_NOTE = "(Big5 外字符由 SC 腿渲染,不计 TC 硬性要求)"


def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3000 <= cp <= 0x9FFF
        or 0xF900 <= cp <= 0xFAFF
        or 0xFF00 <= cp <= 0xFFEF
        or ch in WEB_SYMBOLS
    )


def codec_chars(codec: str, hi_range, lo_range) -> set[str]:
    chars: set[str] = set()
    for hi in hi_range:
        for lo in lo_range:
            if lo == 0x7F:
                continue
            try:
                chars.add(bytes([hi, lo]).decode(codec))
            except UnicodeDecodeError:
                pass
    return chars


def big5_chars() -> set[str]:
    # 与 build_songti_fonts.py 同口径:lead 0xA1-0xF9 全扫
    return codec_chars("big5", range(0xA1, 0xFA), range(0x40, 0xFF))


def scan_site_chars() -> tuple[set[str], set[str]]:
    """扫描 site/src/** 与 site/public/** 文本文件,按语言腿拆分(规格 §6:Web 端按页面实际用字做子集)。

    返回 (sc_chars, tc_chars):
      sc_chars = en 页面(pages/en/**)+ 双语言共享文件(组件/布局/数据/样式/脚本)+ public 文本
                 —— SC 腿在站内只渲染 en 页面的点缀中文(简中站以后再做),不背全量字表;
      tc_chars = zh-hant 页面(pages/zh-hant/**)+ 同一批共享文件 + public 文本
                 —— zh-hant 页是正文主消费者。
      术语表(term_translations.py)只进 TC(zh-hant 内容的术语以它为事实源)。
    """
    # ---- SC 腿:改扫构建产物(2026-11-28 外评根治)----
    # 扫源码时 content.config.ts / global.css / remark 插件里的中文注释与
    # 报错文案全被当"正文用字"收进 SC(en 页实显 113 字 vs 收 795 字,en
    # 访客白背 ~100KB)。产物是渲染面的真值:en 页 html = SC 腿全部实显
    # (含共享组件渲染结果,如语言切换「繁體中文」与天干 zh-l 点缀);
    # zh-hant 页 html 中 Big5 外字符也由 SC 腿兜底渲染(hant_subset 同口径)。
    dist = SITE / "dist"
    if not dist.is_dir():
        raise RuntimeError(
            f"site/dist 不存在:{dist}。SC 腿按构建产物取字(2026-11-28),"
            f"先 `cd site && npm run build` 再跑本脚本(--verify 同样要求;)"
            f"——不静默回落源码扫描,那正是本修复要消灭的口径。")
    sc: set[str] = set()
    big5 = big5_chars() | set(WEB_SYMBOLS)
    # 产物两种布局都要扫:dist/<lang>/**.html 与顶层 dist/<lang>.html
    # (首页是 en.html 文件而非 en/index.html——2026-11-28 实测漏扫首页,
    # 品牌字兜底巧合盖住,不靠巧合)
    pages: list[tuple[str, Path]] = []
    for sub in ("en", "zh-hant"):
        base = dist / sub
        if base.is_dir():
            pages += [(sub, p) for p in sorted(base.rglob("*.html"))]
        top = dist / f"{sub}.html"
        if top.is_file():
            pages.append((sub, top))
    for sub, path in pages:
        chars = {ch for ch in path.read_text(encoding="utf-8") if is_cjk(ch)}
        if sub == "en":
            sc |= chars
        else:
            sc |= {ch for ch in chars if ch not in big5}

    # ---- TC 腿:源码扫描 + 术语表全量(事实源;占位页未显示的术语字也须备好)----
    tc: set[str] = set()
    for base in (SITE / "src", SITE / "public"):
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in SCAN_EXTS:
                continue
            chars = {ch for ch in path.read_text(encoding="utf-8") if is_cjk(ch)}
            rel = path.relative_to(SITE).as_posix()
            if rel.startswith("src/pages/zh-hant"):
                tc |= chars
            elif rel.startswith("src/data/terms"):
                # 术语数据只进 TC(2026-11-27):en 页不背全量术语字表;
                # en 页实显的天干点缀已随产物扫描进 SC(en_rendered_term_chars
                # 的兜底并集保留,双保险无害)
                tc |= chars
            else:
                # 共享文件只灌 TC(SC 腿已走产物,源码注释/报错文案不是渲染面)
                tc |= chars
    return sc, tc


def en_rendered_term_chars() -> set[str]:
    """en 页实际渲染的 terms.json 派生 CJK —— 十天干 zhHant(Footer 共享组件
    的 zh-l 点缀,terms 数据只进 TC 腿后这是唯一落在 en 页上的术语字面)。
    2026-11-27 复核:terms.json 改道只进 TC 后,丁/辛曾实际缺字(其余 8 干靠
    别的共享文件巧合覆盖)——SC 硬性集合必须显式收录,不靠巧合。
    后续共享组件若在 en 页渲染更多 terms 派生 CJK(如五行字),须同步扩这里;
    读取/解析失败直接抛(错误显式传播,不静默降级)。"""
    data = json.loads(TERMS_JSON.read_text(encoding="utf-8"))
    chars: set[str] = set()
    for entry in data["groups"]["heavenlyStems"].values():
        # 严格取键:导出条目缺 zhHant 直接 KeyError 炸出,不静默空集
        chars |= {ch for ch in entry["zhHant"] if is_cjk(ch)}
    return chars


CALENDAR_JSON = SITE / "src" / "data" / "calendar.json"
SOLAR_TERM_COUNT = 24  # 二十四节气
GANZHI_CHAR_COUNT = 22  # 十天干 + 十二地支(干支组合的字元全集)


def en_date_varying_chars() -> set[str]:
    """en 首页「今日」条随日期变化的 CJK —— 年/月/日三柱干支 + 当前/下一节气名。

    SC 腿按构建产物取字,而产物只含**构建当天**的值:2026-11-28 外评发现
    24 个节气名缺 20 个字(12-21「冬至」会掉系统字体),每天重建也抓不到
    (重建只换页面不换字体,verify 也只看当天)。修法与 en_rendered_term_chars
    同思路:从 calendar.json(后端引擎导出的确定性数据)整体收全部可能值。
    TC 腿不受此坑:calendar.json 作为共享文件已整体进 TC 源码扫描。
    断言节气 24 个 / 干支字 22 个——导出窗缩短导致覆盖不全时 FAIL,
    不静默产出缺字字体(错误显式传播)。"""
    data = json.loads(CALENDAR_JSON.read_text(encoding="utf-8"))
    days = data["days"] if isinstance(data, dict) else data
    if not days:
        raise RuntimeError(f"{CALENDAR_JSON} 无任何日条目,en 首页「今日」条将渲染空")
    jieqi = {d["jieqi"] for d in days} | {d["nextJieqi"] for d in days}
    jieqi.discard(None)
    if len(jieqi) != SOLAR_TERM_COUNT:
        raise RuntimeError(
            f"{CALENDAR_JSON} 只覆盖 {len(jieqi)} 个节气(期望 {SOLAR_TERM_COUNT}),"
            f"导出窗须含完整一年;缺:{sorted(jieqi)}")
    ganzhi: set[str] = set()
    for d in days:
        for k in ("y", "m", "d"):
            for ch in d[k]:
                if is_cjk(ch):
                    ganzhi.add(ch)
    if len(ganzhi) != GANZHI_CHAR_COUNT:
        raise RuntimeError(
            f"{CALENDAR_JSON} 干支字只出现 {len(ganzhi)} 个(期望 {GANZHI_CHAR_COUNT} = "
            f"十干+十二支),导出窗须 ≥60 天;缺字集合见:'{''.join(sorted(ganzhi))}'")
    chars = set("".join(jieqi)) | ganzhi
    return {ch for ch in chars if is_cjk(ch)}


def scan_hard_chars(sc_chars: set[str], tc_chars: set[str]) -> tuple[set[str], set[str]]:
    """返回 (SC 硬性要求, TC 硬性要求)。

    SC = en 页/共享文件实际用字 ∪ en 页渲染的天干点缀 ∪ 日期变字(节气/干支)∪ 品牌字(简体);
    TC = zh-hant 页/共享文件用字 ∪ 术语表全部 CJK(术语单一事实源)∪ 品牌字(繁体)。
    术语表不再整体进 SC:简中站「以后再做」,SC 在站内只服务 en 页点缀,
    全量术语字表曾把 SC 撑到 1179 字形(304KB),en 页为此背 300KB + 364ms 的
    一次性 CFF 应用开销(S01 trace 实测),与规格 §6「按页面实际用字做子集」冲突;
    但 en 页**确实渲染**的天干 zh-l 点缀必须收录(en_rendered_term_chars)。
    """
    term = {ch for ch in TERM_TRANSLATIONS.read_text(encoding="utf-8") if is_cjk(ch)}
    brand = set("观觀命")
    # OG 分享图用字(tools/build_site_og.py 的 OG 表是单一事实源,这里导入消费):
    # 图上是 PNG 渲染,不进 dist 扫描,必须在硬性集合显式收,否则掉系统字体
    from build_site_og import og_image_chars
    og_sc, og_tc = og_image_chars()
    # 日期变字(节气名/干支)必须进 SC 硬性集合:SC 腿扫产物只含构建当天的值
    return (sc_chars | brand | en_rendered_term_chars() | en_date_varying_chars() | og_sc,
            tc_chars | term | brand | og_tc)


def rename_family(font: TTFont, family: str, style: str) -> None:
    """与 build_songti_fonts.py 同口径:nameID 1/2/3/4/6 对全部语言记录覆写,删 16/17 残留。"""
    ps = f"{family.replace(' ', '')}-{style}"
    override = {1: family, 2: style, 3: f"{ps};KnowFate", 4: f"{family} {style}", 6: ps}
    for record in list(font["name"].names):
        if record.nameID in override:
            record.string = override[record.nameID]
    font["name"].names = [r for r in font["name"].names if r.nameID not in (16, 17)]


def subset_unicodes(source: Path, out: Path, unicodes: set[int], family: str, style: str) -> None:
    opts = subset.Options()
    opts.name_IDs = list(range(0, 32))
    opts.name_languages = ["*"]
    opts.glyph_names = False
    opts.recalc_bounds = True
    opts.layout_features = ["*"]  # 保留 vert/vrt2(竖排题签)
    font = subset.load_font(str(source), opts)
    subsetter = subset.Subsetter(options=opts)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    rename_family(font, family, style)
    font.flavor = "woff2"
    font.save(str(out))


def _newsreader_from_instance(font: TTFont, out: Path, style: str) -> None:
    """Newsreader 走独立子集流程:实例化后的可变字体(opsz 轴保留)直接 subset+rename+save,
    不能复用 subset_unicodes(它会从源文件重读、丢掉 instancer 结果)。"""
    opts = subset.Options()
    opts.name_IDs = list(range(0, 32))
    opts.name_languages = ["*"]
    opts.glyph_names = False
    opts.recalc_bounds = True
    opts.layout_features = ["*"]
    subsetter = subset.Subsetter(options=opts)
    subsetter.populate(unicodes=NR_UNICODES)
    subsetter.subset(font)
    rename_family(font, FAMILY_NR, style)
    font.flavor = "woff2"
    font.save(str(out))


def hant_subset(chars: set[str]) -> set[str]:
    """TC 腿硬性要求 = 硬字符 ∩ (Big5 ∪ 符号);口径与 build_songti_fonts.py 一致。"""
    allowed = big5_chars() | set(WEB_SYMBOLS)
    return {ch for ch in chars if ch in allowed}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_all(hard_sc: set[str], hard_tc: set[str]) -> list[Path]:
    FONTS_OUT.mkdir(parents=True, exist_ok=True)

    # 中文:从 iOS 已子集的 QiSongti 再按字表二次子集
    zh_jobs = [
        (SC_SOURCE, FONTS_OUT / "knowfate-sc.woff2", FAMILY_SC, {ord(c) for c in hard_sc}),
        (TC_SOURCE, FONTS_OUT / "knowfate-tc.woff2", FAMILY_TC, {ord(c) for c in hant_subset(hard_tc)}),
    ]

    def build_once(target_dir: Path) -> list[Path]:
        made: list[Path] = []
        for source, out, family, unicodes in zh_jobs:
            dest = target_dir / out.name
            subset_unicodes(source, dest, unicodes, family, "Regular")
            made.append(dest)
        for name, src, wght, style in NEWSREADER_INSTANCES:
            # recalcTimestamp=False:TTFont 默认保存时刷新 head.modified(当前时间),
            # 是 instancer 路径非确定性的来源;中文路径走 subset.load_font 无此问题。
            font = TTFont(str(src), recalcTimestamp=False)
            instancer.instantiateVariableFont(font, {"wght": wght}, inplace=True)
            dest = target_dir / name
            _newsreader_from_instance(font, dest, style)
            made.append(dest)
        return made

    # 确定性自检:全部产物双跑比对字节;不一致 → FAIL(不静默写入)
    outputs: list[Path] = []
    with tempfile.TemporaryDirectory() as td:
        run1, run2 = Path(td) / "run1", Path(td) / "run2"
        run1.mkdir()
        run2.mkdir()
        made1 = build_once(run1)
        made2 = build_once(run2)
        for a, b in zip(made1, made2):
            if sha256(a) != sha256(b):
                raise RuntimeError(f"字体构建非确定性:{a.name} 两次产出字节不同")
        for f in made1:
            dest = FONTS_OUT / f.name
            dest.write_bytes(f.read_bytes())
            outputs.append(dest)
    return outputs


def verify(hard_sc: set[str], hard_tc: set[str]) -> list[str]:
    problems: list[str] = []

    def check_font(out: Path, family: str, style: str, need: set[str], label: str) -> None:
        if not out.exists():
            problems.append(f"{label}: 产物不存在 {out}(先跑构建模式)")
            return
        font = TTFont(str(out))
        cmap = font.getBestCmap()
        families = {r.toUnicode() for r in font["name"].names if r.nameID == 1}
        styles = {r.toUnicode() for r in font["name"].names if r.nameID == 2}
        if families != {family}:
            problems.append(f"{label}: nameID 1 = {families},应为 {{'{family}'}}")
        if styles != {style}:
            problems.append(f"{label}: nameID 2 = {styles},应为 {{'{style}'}}")
        missing = sorted(ch for ch in need if ord(ch) not in cmap)
        if missing:
            problems.append(f"{label}: 硬性字符缺失 {len(missing)} 个: {''.join(missing[:50])}")
        kb = out.stat().st_size / 1024
        print(f"{label}: {font['maxp'].numGlyphs} glyphs, {kb:.1f} KB, "
              f"覆盖硬性字符 {len(need) - len(missing)}/{len(need)}")

    check_font(FONTS_OUT / "knowfate-sc.woff2", FAMILY_SC, "Regular", hard_sc, "SC(knowfate-sc)")
    check_font(FONTS_OUT / "knowfate-tc.woff2", FAMILY_TC, "Regular", hant_subset(hard_tc), f"TC(knowfate-tc) {BIG5_ONLY_NOTE}")
    nr_need = {chr(c) for c in NR_UNICODES}
    check_font(FONTS_OUT / "newsreader-400.woff2", FAMILY_NR, "Regular", nr_need, "Newsreader 400")
    check_font(FONTS_OUT / "newsreader-300.woff2", FAMILY_NR, "Regular", nr_need, "Newsreader 300")
    check_font(FONTS_OUT / "newsreader-italic-300.woff2", FAMILY_NR, "Italic", nr_need, "Newsreader italic 300")

    for out in sorted(FONTS_OUT.glob("*.woff2")):
        kb = out.stat().st_size / 1024
        if out.name.startswith("knowfate") and kb > 400:
            print(f"⚠ {out.name} {kb:.1f} KB 超过 400KB 预算(验收允许,须在交付报告写实测值和原因)")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true", help="只校验 site/public/fonts 已有产物")
    args = parser.parse_args()

    # Newsreader 源完整性(SHA256 漂移 → 构建产物不可复现,直接 FAIL)
    for name, expected in NEWSREADER_SHA256.items():
        p = NEWSREADER_DIR / name
        if not p.exists():
            print(f"FAIL: Newsreader 源缺失 {p}(见 tools/site-fonts-src/README.md 下载地址)", file=sys.stderr)
            return 1
        actual = sha256(p)
        if actual != expected:
            print(f"FAIL: {name} SHA256 与登记不符(实际 {actual},登记 {expected});"
                  f"若确要换源,tools/site-fonts-src/README.md 与本脚本须同改", file=sys.stderr)
            return 1

    sc_chars, tc_chars = scan_site_chars()
    hard_sc, hard_tc = scan_hard_chars(sc_chars, tc_chars)
    print(f"站点扫描 CJK:en/共享 {len(sc_chars)} 字,zh-hant/共享 {len(tc_chars)} 字;"
          f"硬性要求 SC {len(hard_sc)} 字 / TC {len(hard_tc)} 字")

    if not args.verify:
        for src, label in [(SC_SOURCE, "SC 源(iOS QiSongti)"), (TC_SOURCE, "TC 源(iOS QiSongtiTC)")]:
            if not src.exists():
                print(f"FAIL: {label}不存在:{src}", file=sys.stderr)
                return 1
        sc_cmap = TTFont(str(SC_SOURCE)).getBestCmap()
        missing_sc = sorted(c for c in hard_sc if ord(c) not in sc_cmap)
        if missing_sc:
            print(f"FAIL: SC 源缺硬性字符 {len(missing_sc)} 个:{''.join(missing_sc[:50])}", file=sys.stderr)
            return 1
        outputs = build_all(hard_sc, hard_tc)
        print("已写入:" + ", ".join(f.name for f in outputs))

    problems = verify(hard_sc, hard_tc)
    if problems:
        print("FAIL:", file=sys.stderr)
        for p in problems:
            print(" -", p, file=sys.stderr)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
