#!/usr/bin/env python3
"""生成官网 OG 分享图(site/public/og/<type>-<lang>.png)—— S06。

方案(2026-11-28 用户拍板「降级:按页面类型静态图」):不做逐页 Satori,
五类页面类型 × 两语言 = 10 张 1200×630 静态图,页面层经 ogPath() 引用。
视觉与站内同源:宣纸底 / Newsreader 标题 / 思源宋体大字 / 墨圆 enso
(feTurbulence 毛边,路径同 Enso.astro)/ 朱印(观/觀)+ KNOWFATE.APP。

渲染:Chrome headless --screenshot(本机已有 Chrome,零新依赖;Pillow 未批,
尺寸校验直接读 PNG IHDR)。字体 base64 内联进临时 HTML,file:// 与
--allow-file-access-from-files 都不依赖,跨环境行为一致。

用字护栏:OG 图上的全部 CJK 由 build_site_fonts.py 经 og_image_chars()
(本模块导出)收进字体硬性集合——本表改字不重跑字体构建 = 图上掉系统字体。
改 OG 文案/字体后:重跑 build_site_fonts.py + build_site_og.py。

排版护栏(2026-11-28 review):渲染期对每张图跑 Chrome --dump-dom 探针,量
.title 的行数(getClientRects)与 .sub 上沿到 .title 下沿的间距——标题折行或
副题重叠(曾在 library-en/calculator-en 双图实测叠字)直接 FAIL,不靠人工抽检。

过期判定(2026-11-28 review,取代 mtime):渲染时把三方内容哈希写进
site/public/og/manifest.json(script 自身 / 四个字体 / 十张 PNG);--check 重算
比对,并按漂移源分流提示(git 不保 mtime,新 clone 上 mtime 法必假失败;
反向地,只重跑本脚本用旧字体渲染 tofu 图也曾被 mtime 法放过)。
--check 另对 committed 字体 cmap 逐字验证 OG 文案(宽谓词,含全角形式),
兜住「字体没重建就重渲染」的错误修法。

用法(仓库根):python3 tools/build_site_og.py [--check]
  --check 只校验已提交 PNG(存在 + 1200×630 + manifest 一致 + 文案字在字体 cmap),不重渲染。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from html import unescape
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SITE = REPO / "site"
FONTS = SITE / "public" / "fonts"
OG_OUT = SITE / "public" / "og"
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

W, H = 1200, 630

# ---- 文案单一事实源(build_site_fonts.py 从这里取字)----
# glyph: enso 里的大字;seal: 朱印印文;title/sub: 图上文字。
# en 腿文案保持纯 ASCII(SC 子集只硬收 glyph/seal 字);zh-hant 文案用字
# 全部经 og_image_chars() 进 TC 硬性集合。
OG_PAGES: dict[str, dict] = {
    "home": {
        "glyph": "命",
        "en": {"title": "KnowFate", "sub": "Chinese astrology, honestly read"},
        "zh-hant": {"title": "觀命", "sub": "子平八字,誠實地讀"},
    },
    "calculator": {
        "glyph": "命",
        "en": {"title": "BaZi Calculator", "sub": "True solar time, 23:00 boundary"},
        "zh-hant": {"title": "免費八字排盤", "sub": "真太陽時 · 23:00 換日"},
    },
    "library": {
        "glyph": "書",
        "en": {"title": "KnowFate Library", "sub": "Day masters, ten gods, five elements"},
        "zh-hant": {"title": "觀命知識庫", "sub": "日主 · 十神 · 五行"},
    },
    "day-master": {
        "glyph": "甲",
        "en": {"title": "Ten Day Masters", "sub": "Start from your stem"},
        "zh-hant": {"title": "十日主", "sub": "從你的日主讀起"},
    },
    "page": {
        "glyph": "觀",
        "en": {"title": "KnowFate", "sub": "A BaZi app, carefully made"},
        "zh-hant": {"title": "觀命", "sub": "八字命理 App"},
    },
}
OG_LANGS = ("en", "zh-hant")

SEAL = {"en": "观", "zh-hant": "觀"}

# calculator 用「盤」更贴题,但 SC 腿(en 图)不背 盤 字(简体排盘语境用 盘);
# glyph 按语言分写的放这里,缺省回退 OG_PAGES[type]["glyph"]
OG_GLYPH_BY_LANG: dict[tuple[str, str], str] = {
    ("calculator", "en"): "盘",
    ("calculator", "zh-hant"): "盤",
    ("library", "en"): "书",
    ("library", "zh-hant"): "書",
    ("page", "en"): "观",
    ("page", "zh-hant"): "觀",
}


def is_cjk(ch: str) -> bool:
    # 同步锚:与 build_site_fonts.py 的宽谓词 CJK/全角区间保持一致(2026-11-28
    # review RT2——两处漂移曾让全角标点漏出 TC 硬集)。反向 import 会成环
    # (fonts 已 function-level import 本模块),只靠锚注;fonts 侧另有
    # WEB_SYMBOLS 属站内词条集,OG 文案不经它。--check 的 cmap 逐字验证兜底。
    cp = ord(ch)
    return 0x3000 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF or 0xFF00 <= cp <= 0xFFEF


def og_image_chars() -> tuple[set[str], set[str]]:
    """(SC 硬性补字, TC 硬性补字)。build_site_fonts.py 消费,单一事实源。

    SC(en 图实显):glyph + 印文;TC(zh-hant 图实显):glyph + 印文 + 全部文案字。"""
    sc: set[str] = set()
    tc: set[str] = set()
    for type_, page in OG_PAGES.items():
        for lang in OG_LANGS:
            glyph = OG_GLYPH_BY_LANG.get((type_, lang), page["glyph"])
            chars = {ch for ch in glyph + SEAL[lang] if is_cjk(ch)}
            if lang == "en":
                sc |= chars
            else:
                tc |= chars
                tc |= {ch for ch in page["zh-hant"]["title"] + page["zh-hant"]["sub"] if is_cjk(ch)}
    # en 文案要求纯 ASCII:混入 CJK 说明表改坏了,构建期炸而不是静默掉字
    for page in OG_PAGES.values():
        for f in ("title", "sub"):
            bad = [ch for ch in page["en"][f] if is_cjk(ch) or ord(ch) > 0x7F]
            if bad:
                raise ValueError(f"OG en 文案须纯 ASCII,发现 {bad!r}")
    return sc, tc


def font_b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def render_html(type_: str, lang: str) -> str:
    page = OG_PAGES[type_]
    glyph = OG_GLYPH_BY_LANG.get((type_, lang), page["glyph"])
    copy = page[lang]
    zh = lang != "en"
    # zh-hant 图标题走宋体,拉丁走 Newsreader;display 尺寸中文略收(等视觉量级)。
    # zh 栈补 'Newsreader' 回退:文案里的 ASCII/间隔号等 QiSongti 未收的字
    # 落在 OS 默认字体上(2026-11-28 review,design #88),回退到同图 en 腿字体。
    title_style = (
        "font-family:'QiSongti','Newsreader',serif;font-weight:400;font-size:66px;letter-spacing:.06em;"
        if zh else "font-family:'Newsreader',serif;font-weight:400;font-size:74px;letter-spacing:-.015em;"
    )
    sub_style = (
        "font-family:'QiSongti','Newsreader',serif;font-weight:400;font-size:27px;"
        if zh else "font-family:'Newsreader',serif;font-style:italic;font-weight:300;font-size:29px;"
    )
    # kicker:品牌词 ◆(朱红菱形点)类型词,同站内 .kicker .dot 形制
    kicker_html = (
        f'觀命<span class="dot"></span>子平八字' if zh else 'KNOWFATE<span class="dot"></span>CHINESE ASTROLOGY'
    )
    fonts = {
        "nr": font_b64(FONTS / "newsreader-400.woff2"),
        "nri": font_b64(FONTS / "newsreader-italic-300.woff2"),
        "zh": font_b64(FONTS / ("knowfate-tc.woff2" if zh else "knowfate-sc.woff2")),
    }
    return f"""<!DOCTYPE html>
<html lang="{'zh-Hant' if zh else 'en'}"><head><meta charset="utf-8">
<style>
  @font-face {{ font-family:'Newsreader'; font-weight:400; src:url(data:font/woff2;base64,{fonts['nr']}) format('woff2'); }}
  @font-face {{ font-family:'Newsreader'; font-weight:300; font-style:italic; src:url(data:font/woff2;base64,{fonts['nri']}) format('woff2'); }}
  @font-face {{ font-family:'QiSongti'; src:url(data:font/woff2;base64,{fonts['zh']}) format('woff2'); }}
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  html, body {{ width:{W}px; height:{H}px; overflow:hidden; }}
  body {{ background:#E7E2D5; font-family:'Newsreader',serif; position:relative; }}
  .frame {{ position:absolute; inset:26px; border:1px solid rgba(28,27,30,.22); }}
  .kicker {{ position:absolute; left:84px; top:132px; font-family:-apple-system,'Helvetica Neue',sans-serif;
    font-size:12.5px; font-weight:500; letter-spacing:.26em; color:#1C1B1E; }}
  .dot {{ display:inline-block; width:5px; height:5px; background:#A83226; transform:rotate(45deg); margin:0 12px 2px; vertical-align:middle; }}
  .title {{ position:absolute; left:84px; top:186px; max-width:620px; color:#17161A; line-height:1.08; {title_style} }}
  .sub {{ position:absolute; left:84px; top:{('288' if not zh else '282')}px; max-width:600px; color:rgba(28,27,30,.62); {sub_style} }}
  .enso {{ position:absolute; right:64px; top:92px; width:446px; height:446px; }}
  .enso path {{ stroke:#17161A; fill:none; stroke-linecap:round; }}
  .glyph {{ position:absolute; right:64px; top:92px; width:446px; height:446px; display:grid; place-items:center;
    font-family:'QiSongti'; font-size:212px; color:#17161A; }}
  .brand {{ position:absolute; left:84px; bottom:76px; display:flex; align-items:center; gap:16px; }}
  .seal {{ width:44px; height:44px; display:grid; place-items:center; background:#A83226; color:#F7F1EA;
    font-family:'QiSongti'; font-size:25px; transform:rotate(-4deg); border-radius:3px;
    box-shadow:inset 0 0 0 1.5px rgba(247,241,234,.55), inset 0 0 0 3px #A83226; }}
  .brand span {{ font-family:-apple-system,'Helvetica Neue',sans-serif; font-size:12.5px; font-weight:500;
    letter-spacing:.3em; color:rgba(28,27,30,.7); }}
</style></head>
<body>
  <div class="frame"></div>
  <p class="kicker">{kicker_html}</p>
  <h1 class="title">{copy['title']}</h1>
  <p class="sub">{copy['sub']}</p>
  <svg class="enso" viewBox="0 0 440 440">
    <defs><filter id="e" x="-10%" y="-10%" width="120%" height="120%">
      <feTurbulence type="fractalNoise" baseFrequency="0.045" numOctaves="4" seed="3" result="n"/>
      <feDisplacementMap in="SourceGraphic" in2="n" scale="9"/>
    </filter></defs>
    <path d="M285.7,96.4 A140,140 0 1,0 356.9,249.1" stroke-width="13" filter="url(#e)"/>
  </svg>
  <div class="glyph">{glyph}</div>
  <div class="brand"><div class="seal">{SEAL[lang]}</div><span>KNOWFATE.APP</span></div>
  {PROBE_JS}
</body></html>"""


def png_size(path: Path) -> tuple[int, int]:
    """读 PNG IHDR(不依赖 Pillow;PNG 签名 8B + IHDR 长度/类型 8B + wh 8B)。"""
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError(f"{path}: 不是合法 PNG")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


# 渲染期排版探针(2026-11-28 review):量 .title 行数(getClientRects)与 .sub
# 上沿到 .title 下沿的间距,写进 body[data-og-probe];render() 用 --dump-dom
# 读回,折行或间距不足直接抛错(library-en/calculator-en 曾实测叠字,不靠抽检)。
# 属性值里的 JSON 引号会被序列化成 &quot;,取回后 unescape。
PROBE_JS = """<script>
(function () {
  function ready(fn) { if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn); else fn(); }
  ready(function () {
    var t = document.querySelector('.title'), s = document.querySelector('.sub');
    if (!t || !s) return;
    var lines = t.getClientRects().length;
    var gap = Math.round(s.getBoundingClientRect().top - t.getBoundingClientRect().bottom);
    document.body.setAttribute('data-og-probe', JSON.stringify({ lines: lines, gap: gap }));
  });
})();
</script>"""


def render(type_: str, lang: str, out: Path) -> None:
    html = render_html(type_, lang)
    with tempfile.TemporaryDirectory(prefix="kf-og-") as td:
        src = Path(td) / "og.html"
        src.write_text(html, encoding="utf-8")
        shot = Path(td) / "shot.png"
        # --virtual-time-budget:等字体解码/SVG filter 落定再截
        proc = subprocess.run(
            [str(CHROME), "--headless=new", "--disable-gpu", "--hide-scrollbars",
             f"--window-size={W},{H}", "--virtual-time-budget=4000",
             f"--screenshot={shot}", f"file://{src}"],
            capture_output=True, text=True, timeout=120,
        )
        if proc.returncode != 0 or not shot.is_file():
            raise RuntimeError(f"Chrome 截图失败({type_}-{lang}):rc={proc.returncode} {proc.stderr[:400]}")
        # 同一 HTML 再跑一遍 --dump-dom 读探针(只设属性,不影响截图版式)
        probe_proc = subprocess.run(
            [str(CHROME), "--headless=new", "--disable-gpu", "--hide-scrollbars",
             f"--window-size={W},{H}", "--virtual-time-budget=4000",
             "--dump-dom", f"file://{src}"],
            capture_output=True, text=True, timeout=120,
        )
        if probe_proc.returncode != 0:
            raise RuntimeError(f"Chrome dump-dom 失败({type_}-{lang}):rc={probe_proc.returncode} {probe_proc.stderr[:400]}")
        m = re.search(r'data-og-probe="([^"]*)"', probe_proc.stdout)
        if not m:
            raise RuntimeError(f"OG {type_}-{lang}: 排版探针未写入(内联脚本未执行)")
        probe = json.loads(unescape(m.group(1)))
        if probe["lines"] != 1:
            raise RuntimeError(f"OG {type_}-{lang}: 标题折成 {probe['lines']} 行(缩短文案,单行宽度上限 620px)")
        if probe["gap"] < 12:
            raise RuntimeError(f"OG {type_}-{lang}: 副题与标题间距 {probe['gap']}px(<12,重叠)")
        w, h = png_size(shot)
        if (w, h) != (W, H):
            raise RuntimeError(f"OG {type_}-{lang} 尺寸 {w}x{h}(期望 {W}x{H})")
        out.write_bytes(shot.read_bytes())


FONT_FILES = ("knowfate-sc.woff2", "knowfate-tc.woff2",
              "newsreader-400.woff2", "newsreader-italic-300.woff2")
MANIFEST = OG_OUT / "manifest.json"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def og_copy_chars_for_cmap() -> dict[str, set[str]]:
    """--check 的 cmap 验证用:按渲染宽谓词(含全角形式)收集每条腿实显的全部字。"""
    legs: dict[str, set[str]] = {"sc": set(), "tc": set()}
    for type_, page in OG_PAGES.items():
        for lang in OG_LANGS:
            glyph = OG_GLYPH_BY_LANG.get((type_, lang), page["glyph"])
            chars = {ch for ch in glyph + SEAL[lang] + page[lang]["title"] + page[lang]["sub"]
                     if is_cjk(ch)}
            legs["sc" if lang == "en" else "tc"] |= chars
    return legs


def _cmap_codepoints(font_path: Path) -> set[int]:
    from fontTools.ttLib import TTFont  # build_site_fonts.py 同源依赖;--check 才 import
    font = TTFont(str(font_path))
    cmap = font.getBestCmap() or {}
    return set(cmap.keys())


def _check_staleness() -> None:
    """manifest 三方内容哈希比对,按漂移源分流提示(取代 mtime:git 不保 mtime,
    新 clone 上 mtime 法必假失败;反向地,旧字体渲染的 tofu 图也曾被 mtime 放过)。"""
    try:
        saved = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"FAIL: {MANIFEST.relative_to(REPO)} 不存在——先跑 python3 tools/build_site_og.py")
    drift: list[str] = []
    if saved.get("script_sha") != _sha256(Path(__file__)):
        drift.append("OG 脚本/文案变了 → 先 python3 tools/build_site_fonts.py 再 python3 tools/build_site_og.py")
    saved_fonts = saved.get("fonts", {})
    for f in FONT_FILES:
        if saved_fonts.get(f) != _sha256(FONTS / f):
            drift.append(f"字体 {f} 变了 → python3 tools/build_site_og.py 重渲染(若字集变化先 build_site_fonts.py)")
    saved_pngs = saved.get("pngs", {})
    for t in OG_PAGES:
        for l in OG_LANGS:
            name = f"{t}-{l}.png"
            if saved_pngs.get(name) != _sha256(OG_OUT / name):
                drift.append(f"PNG {name} 与 manifest 不符 → 重跑 python3 tools/build_site_og.py")
    if drift:
        raise SystemExit("FAIL: OG 产物过期:\n  " + "\n  ".join(sorted(set(drift))))


def _check_cmap_coverage() -> None:
    """兜底「顺序跑反」:就算拿旧字体重渲染出 tofu 图,文案字不在 committed 字体 cmap 里也拦下。"""
    try:
        legs = og_copy_chars_for_cmap()
        sc_glyphs = _cmap_codepoints(FONTS / "knowfate-sc.woff2")
        tc_glyphs = _cmap_codepoints(FONTS / "knowfate-tc.woff2")
    except ImportError:
        raise SystemExit("FAIL: --check 的 cmap 校验需要 fontTools(build_site_fonts.py 同源依赖,pip install fonttools)")
    miss_sc = sorted(hex(ord(c)) for c in legs["sc"] if ord(c) not in sc_glyphs)
    miss_tc = sorted(hex(ord(c)) for c in legs["tc"] if ord(c) not in tc_glyphs)
    if miss_sc or miss_tc:
        raise SystemExit(
            f"FAIL: OG 文案字不在字体子集(SC 缺 {miss_sc} / TC 缺 {miss_tc})"
            "——先 python3 tools/build_site_fonts.py 重建字集,再 python3 tools/build_site_og.py 重渲染")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="只校验已提交产物(存在/尺寸/manifest 一致/文案字在字体 cmap),不重渲染")
    args = ap.parse_args()

    if not CHROME.is_file() and not args.check:
        raise SystemExit(f"Chrome 不存在:{CHROME}(OG 渲染依赖本机 Chrome,见脚本头)")

    OG_OUT.mkdir(parents=True, exist_ok=True)
    for type_ in OG_PAGES:
        for lang in OG_LANGS:
            out = OG_OUT / f"{type_}-{lang}.png"
            if args.check:
                if not out.is_file():
                    raise SystemExit(f"FAIL: {out.relative_to(REPO)} 不存在")
                w, h = png_size(out)
                if (w, h) != (W, H):
                    raise SystemExit(f"FAIL: {out.name} 尺寸 {w}x{h}(期望 {W}x{H})")
                continue
            render(type_, lang, out)
            print(f"og: {out.relative_to(REPO)} ({out.stat().st_size // 1024} KB)")

    if args.check:
        _check_staleness()
        _check_cmap_coverage()
        print(f"check_site_og: PASS({len(OG_PAGES) * len(OG_LANGS)} 张 {W}x{H},manifest+cmap 一致)")
    else:
        MANIFEST.write_text(json.dumps({
            "script_sha": _sha256(Path(__file__)),
            "fonts": {f: _sha256(FONTS / f) for f in FONT_FILES},
            "pngs": {f"{t}-{l}.png": _sha256(OG_OUT / f"{t}-{l}.png")
                     for t in OG_PAGES for l in OG_LANGS},
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"og: manifest → {MANIFEST.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
