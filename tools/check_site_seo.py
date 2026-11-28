#!/usr/bin/env python3
"""官网 SEO 产物校验(S06)—— 读 site/dist,构建(npm run build)之后跑。

覆盖规格 README §6 的可机检项:
  1  title:全站唯一(语言腿合并计)且 ≤60 字符
  2  description:140–160 字符(noindex 页跳过)
  3  canonical:绝对 URL、全站唯一、与页面自身干净 URL 一致
  4  hreflang:en / zh-Hant / x-default 三条齐,且双向闭合(A 指 B,B 必指回 A)
  5  JSON-LD:每段 application/ld+json 可解析(不校 schema 语义)
  6  og:image:引用存在、PNG、1200×630(尺寸读 IHDR,不依赖 Pillow)
  7  sitemap:index + shard 都在;shard loc ↔ indexable dist 页互为镜像;
     shard 内 xhtml:link 与页面 hreflang 一致;noindex 页不得进 sitemap
  8  robots.txt(含 Sitemap 行)/ llms.txt / 404.html 在位
  9  内链无 404:所有 dist 页(含 noindex 页与 404.html)的站内链接(去
     query/fragment,相对路径按引用页目录归一)能落到 dist 文件
 10  pair 重定向:gen-pair-redirects.mjs 生成段的目标页存在(带 :// 或 * 的
     外链/splat 目标跳过)
 11  og:image 语言腿:文件名 -en/-zh-hant 尾段与页面语言一致
 12  OG 枚举双源:site.ts OG_TYPES ↔ build_site_og.py OG_PAGES 键集相等,
     且 dist/og 文件集 == 类型 × 语言全积(png_size 单源自 build_site_og)

FAIL 语义:任何一项不过 exit 1 并列出全部问题(不静默、不截断)。
用法(仓库根):python3 tools/check_site_seo.py [--dist <dir>]
  --dist 指定 dist 目录(默认 site/dist;site/tests/test_s06.py 负向夹具用)。
"""
from __future__ import annotations

import argparse
import html
import json
import posixpath
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# png_size 单源:build_site_og.py 的 IHDR 解析(含 <33B 短文件护栏)——两处
# 各写一份会漂移(2026-11-28 review,simplification advisory 落地)。
# 自举 script 目录进 sys.path:python3 -I 隔离模式(测试怎么调就怎么跑得通)。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_site_og import png_size

REPO = Path(__file__).resolve().parent.parent
DIST = REPO / "site" / "dist"
DOMAIN = "https://knowfate.app"
SM_NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
XH_NS = "{http://www.w3.org/1999/xhtml}"

TITLE_MAX = 60
# description 语言分带与 tools/check_site_content.py(S02)同一口径:
# en 140–160 字符 / zh-hant 60–90 字(CJK SERP 摘要截断更早,拉长反而伤展示)
DESC_BAND = {"en": (140, 160), "zh-hant": (60, 90)}


def die(errors: list[str]) -> None:
    for e in errors:
        print(f"FAIL: {e}")
    sys.exit(1)


def is_indexable(html: str) -> bool:
    m = re.search(r'<meta name="robots" content="([^"]*)"', html)
    return not (m and "noindex" in m.group(1))


def main() -> int:
    global DIST
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", type=Path, default=None,
                    help="dist 目录(默认 site/dist;负向测试夹具用)")
    args = ap.parse_args()
    if args.dist is not None:
        DIST = args.dist.resolve()

    errors: list[str] = []
    if not DIST.is_dir():
        die([f"dist 不存在:{DIST}——先 `cd site && npm run build`"])

    # ---- 收页(404.html 靠自身 noindex meta 落到 indexable 之外,无代码豁免;
    #      它无 canonical/title,若 meta 被删,下面逐页检查会点名它)----
    files = sorted(p for p in DIST.rglob("*.html"))
    pages: dict[Path, dict] = {}
    for p in files:
        # 局部变量命名避开 html 模块名——函数内任何赋值都会让 html.unescape
        # 解析成字符串属性(首跑即 AttributeError),此处统一用 raw。
        raw = p.read_text(encoding="utf-8")
        info = {
            "html": raw,
            "indexable": is_indexable(raw),
            "title": (re.search(r"<title>(.*?)</title>", raw, re.S) or [None, ""])[1],
            "desc": (re.search(r'<meta name="description" content="([^"]*)"', raw) or [None, None])[1],
            "canonical": (re.search(r'<link rel="canonical" href="([^"]*)"', raw) or [None, None])[1],
            "hreflang": re.findall(r'<link rel="alternate" hreflang="([^"]*)" href="([^"]*)"', raw),
            "og": (re.search(r'<meta property="og:image" content="([^"]*)"', raw) or [None, None])[1],
            "jsonld": re.findall(r'<script type="application/ld\+json"[^>]*>(.*?)</script>', raw, re.S),
        }
        pages[p] = info

    indexable = {p: i for p, i in pages.items() if i["indexable"]}
    if not indexable:
        die(["dist 中没有任何 indexable 页"])

    # ---- 1/2/3/5/6:逐页 ----
    seen_titles: dict[str, str] = {}
    seen_canonicals: dict[str, str] = {}
    for p, i in sorted(indexable.items()):
        rel = p.relative_to(DIST).as_posix()
        # 实体按渲染口径计数(&amp; 渲染为 1 字符);语言腿取自路径前缀
        lang = "zh-hant" if rel.startswith("zh-hant") else "en"
        dmin, dmax = DESC_BAND[lang]
        title = html.unescape(i["title"]).strip()
        if not title:
            errors.append(f"{rel}: 无 <title>")
        elif len(title) > TITLE_MAX:
            errors.append(f"{rel}: title {len(title)} 字符 > {TITLE_MAX}:{title[:70]}…")
        if title in seen_titles:
            errors.append(f"{rel}: title 与 {seen_titles[title]} 重复:{title}")
        elif title:
            seen_titles[title] = rel

        desc = html.unescape(i["desc"]) if i["desc"] is not None else None
        if desc is None:
            errors.append(f"{rel}: 无 meta description")
        elif not (dmin <= len(desc.strip()) <= dmax):
            errors.append(f"{rel}: description {len(desc.strip())} 字符,{lang} 须 {dmin}–{dmax}")

        can = i["canonical"]
        if not can:
            errors.append(f"{rel}: 无 canonical")
        else:
            if not can.startswith(DOMAIN):
                errors.append(f"{rel}: canonical 非绝对 URL:{can}")
            if can in seen_canonicals:
                errors.append(f"{rel}: canonical 与 {seen_canonicals[can]} 重复:{can}")
            else:
                seen_canonicals[can] = rel
            # canonical 必须指向自身干净 URL(dist 相对路径去 .html 即 URL path)
            expect = f"{DOMAIN}/{rel[:-5]}"
            if can.rstrip("/") != expect.rstrip("/"):
                errors.append(f"{rel}: canonical({can})与自身 URL({expect})不一致")

        for n, blob in enumerate(i["jsonld"]):
            try:
                json.loads(blob)
            except json.JSONDecodeError as exc:
                errors.append(f"{rel}: JSON-LD #{n + 1} 解析失败:{exc}")

        og = i["og"]
        if not og:
            errors.append(f"{rel}: 无 og:image")
        else:
            m = re.match(rf"{re.escape(DOMAIN)}/og/([\w-]+\.png)$", og)
            if not m:
                errors.append(f"{rel}: og:image 非站内 /og/ PNG:{og}")
            else:
                stem = m.group(1)[:-4]
                # 语言腿:文件名 -en/-zh-hant 尾缀与页面语言一致(2026-11-28
                # review RT5——en 页引 zh-hant 图此前照样 PASS)。腿取尾缀匹配
                # 而非最后一个连字符段:zh-hant 自带连字符,rsplit 只会拆出
                # hant,真实 dist 上 7 张 zh-hant 页全误报(首轮构建实测);
                # 负向夹具用 en 图恰好无连字符才没暴露。长尾缀先试。
                leg = next((s[1:] for s in ("-zh-hant", "-en") if stem.endswith(s)),
                           stem.rsplit("-", 1)[-1])
                if leg != lang:
                    errors.append(f"{rel}: og:image {m.group(1)} 语言腿 {leg} 与页面语言 {lang} 不符")
                f = DIST / "og" / m.group(1)
                if not f.is_file():
                    errors.append(f"{rel}: og:image 文件缺失:{m.group(1)}(跑 tools/build_site_og.py)")
                else:
                    try:
                        w, h = png_size(f)
                        if (w, h) != (1200, 630):
                            errors.append(f"{rel}: og:image {m.group(1)} 尺寸 {w}x{h}(期望 1200x630)")
                    except (ValueError, RuntimeError) as exc:
                        errors.append(f"{rel}: {exc}")

    # ---- 4 hreflang 闭合 ----
    url_to_file: dict[str, Path] = {}
    for p, i in indexable.items():
        if i["canonical"]:
            url_to_file[i["canonical"].rstrip("/")] = p
    for p, i in sorted(indexable.items()):
        rel = p.relative_to(DIST).as_posix()
        langs = sorted(h[0] for h in i["hreflang"])
        if langs != ["en", "x-default", "zh-Hant"]:
            errors.append(f"{rel}: hreflang 集为 {langs}(期望 en/zh-Hant/x-default)")
            continue
        for lh, lurl in i["hreflang"]:
            target = url_to_file.get(lurl.rstrip("/"))
            if target is None:
                errors.append(f"{rel}: hreflang {lh} 指向不存在/未收录页:{lurl}")
                continue
            back = {h: u for h, u in indexable[target]["hreflang"]}
            mine = {h: u for h, u in i["hreflang"]}
            # 双向:对方在对应语言腿上必须指回本页(en↔zh-Hant 对称;x-default=en 侧)
            self_urls = {u.rstrip("/") for u in mine.values()}
            back_urls = {u.rstrip("/") for u in back.values()}
            if not self_urls <= back_urls:
                errors.append(f"{rel}: hreflang 不闭合——{lurl} 的 alternates {sorted(back_urls)} 未指回 {sorted(self_urls)}")

    # ---- 4b hreflang 语言映射(2026-11-28 review,Codex #3)----
    # 闭合只保证 A↔B 互指,不保证语言对位(en 页的 hreflang en 可以错指
    # zh-hant 腿照样闭合过检)。按「同名异语言腿文件」推导期望值:
    # en/x.html ↔ zh-hant/x.html 互为期望,x-default 恒等于 en 腿。
    # 首页产物是根级 en.html/zh-hant.html(无斜杠前缀),同样要查——
    # 只靠闭合检查抓不住首页语言腿互换(2026-11-28 双 review 轮 1:两页
    # startswith("en/") 均不命中被 continue,恰好是流量最高的盲区)。
    for p, i in sorted(indexable.items()):
        rel = p.relative_to(DIST).as_posix()
        if rel.startswith("en/"):
            alt_rel = "zh-hant/" + rel[len("en/"):]
        elif rel.startswith("zh-hant/"):
            alt_rel = "en/" + rel[len("zh-hant/"):]
        elif rel == "en.html":
            alt_rel = "zh-hant.html"
        elif rel == "zh-hant.html":
            alt_rel = "en.html"
        else:
            continue  # 无语言前缀的页(如根 index),映射无从推导
        sibling = DIST / alt_rel
        if sibling not in indexable:
            continue  # 无异语言腿(闭合检查已覆盖其指向合法性)
        own = (i["canonical"] or "").rstrip("/")
        sib = (indexable[sibling]["canonical"] or "").rstrip("/")
        if rel.startswith("en/") or rel == "en.html":
            want = {"en": own, "x-default": own, "zh-Hant": sib}
        else:
            want = {"en": sib, "x-default": sib, "zh-Hant": own}
        for lh, lurl in i["hreflang"]:
            if lh in want and lurl.rstrip("/") != want[lh]:
                errors.append(
                    f"{rel}: hreflang {lh} 语言映射错位:{lurl}(期望同内容 {lh} 腿 {want[lh]})")

    # ---- 7 sitemap ↔ dist 镜像 ----
    idx = DIST / "sitemap-index.xml"
    robots_txt = DIST / "robots.txt"
    llms = DIST / "llms.txt"
    f404 = DIST / "404.html"
    for f, what in ((idx, "sitemap-index.xml"), (robots_txt, "robots.txt"), (llms, "llms.txt"), (f404, "404.html")):
        if not f.is_file():
            errors.append(f"dist 缺 {what}")
    if errors:
        die(errors)  # 以下检查依赖这些文件,先收口

    robots_body = robots_txt.read_text(encoding="utf-8")
    if f"Sitemap: {DOMAIN}/sitemap-index.xml" not in robots_body:
        errors.append("robots.txt 缺 Sitemap 行(指向 /sitemap-index.xml)")

    try:
        tree = ET.parse(idx)
    except ET.ParseError as exc:
        die([f"sitemap-index.xml 解析失败:{exc}"])
    shard_locs = [e.text for e in tree.getroot().findall(f"{SM_NS}sitemap/{SM_NS}loc") if e.text]
    sitemap_urls: set[str] = set()
    shard_alts: dict[str, dict[str, set[str]]] = {}
    for sloc in shard_locs:
        name = sloc.rsplit("/", 1)[-1]
        f = DIST / name
        if not f.is_file():
            errors.append(f"sitemap-index 引用的 {name} 不在 dist")
            continue
        try:
            st = ET.parse(f)
        except ET.ParseError as exc:
            errors.append(f"{name} 解析失败:{exc}")
            continue
        for url in st.getroot().findall(f"{SM_NS}url"):
            loc = url.find(f"{SM_NS}loc")
            if loc is None or not loc.text:
                errors.append(f"{name}: 有 <url> 无 <loc>")
                continue
            u = loc.text.rstrip("/")
            sitemap_urls.add(u)
            shard_alts.setdefault(u, {})
            for alt in url.findall(f"{XH_NS}link"):
                hl = alt.get("hreflang")
                if hl:
                    shard_alts[u][hl] = alt.get("href", "").rstrip("/")
    expect_urls = {i["canonical"].rstrip("/") for i in indexable.values()}
    for u in sorted(expect_urls - sitemap_urls):
        errors.append(f"indexable 页不在任何 sitemap shard:{u}")
    for u in sorted(sitemap_urls - expect_urls):
        errors.append(f"sitemap 收了不存在/noindex 的页:{u}")
    # shard 内 alternates 与页面 hreflang 一致
    for p, i in indexable.items():
        can = i["canonical"].rstrip("/")
        if can not in shard_alts:
            continue
        page_alts = {h: u.rstrip("/") for h, u in i["hreflang"]}
        if shard_alts[can] != page_alts:
            errors.append(f"{p.relative_to(DIST).as_posix()}: shard alternates 与页面 hreflang 不一致")

    # ---- 8 已并入上节(robots/llms/404 在位)----

    # ---- 9 内链无 404 ----
    def resolve(url: str, page_rel: str = "") -> Path | None:
        """站内 URL → dist 文件(去 query/fragment;format:'file' 布局)。

        相对路径按引用页所在目录归一后解(2026-11-28 review,Codex #8——
        此前直接跳过 = 相对形态的内链 404 盲区);page_rel 为引用页的 dist
        相对 posix 路径,_redirects 等无页面上下文的调用留空则跳过。"""
        if url.startswith("#") or url.startswith(("mailto:", "tel:", "javascript:")):
            return None
        if url.startswith("//"):
            return None  # 协议相对外链(//host/…):startswith("/") 会误判站内,先排除
        if url.startswith("http"):
            if not url.startswith(DOMAIN):
                return None  # 外链
            url = url[len(DOMAIN):]
        if not url.startswith("/"):
            if not page_rel or url == "":
                return None
            joined = posixpath.normpath(posixpath.join(posixpath.dirname(page_rel), url))
            url = "/" + joined
        url = url.split("#")[0].split("?")[0]
        if url == "/" or url == "":
            return None  # 根路径由 _redirects 302 到 /en,不落文件
        clean = url.rstrip("/")
        for cand in (DIST / (clean.lstrip("/") + ".html"), DIST / (clean.lstrip("/") + "/index.html")):
            if cand.is_file():
                return cand
        return DIST / (clean.lstrip("/") + ".html")  # 返回期望路径供报错

    # 全部 dist 页都扫(含 noindex 示例页与 404.html)——404 页恰是用户踩到
    # 死链后的落点,它自己的链接腐烂同样不能无人把关(2026-11-28 双 review 轮 2)。
    for p, i in sorted(pages.items()):
        rel = p.relative_to(DIST).as_posix()
        for href in re.findall(r'<a[^>]+href="([^"]+)"', i["html"]):
            target = resolve(href, rel)
            if target is None:
                continue
            if not target.is_file():
                errors.append(f"{rel}: 内链 404:{href}")

    # ---- 10 pair 重定向目标存在(外链/带通配目标跳过)----
    redirs = DIST / "_redirects"
    if redirs.is_file():
        for line in redirs.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[1].startswith("/"):
                # splat/占位目标(*/:param)与协议外链无法落到静态文件,跳过
                if ":" in parts[1] or "*" in parts[1]:
                    continue
                target = resolve(parts[1])
                if target is not None and not target.is_file():
                    errors.append(f"_redirects 目标不存在:{line}")

    # ---- 11/12 OG 枚举双源 + dist og 文件全积(2026-11-28 review A8/RT3)----
    site_ts = REPO / "site" / "src" / "data" / "site.ts"
    og_py = REPO / "tools" / "build_site_og.py"
    ts_m = re.search(r"OG_TYPES\s*=\s*\[([^\]]*)\]", site_ts.read_text(encoding="utf-8"))
    py_m = re.search(r"OG_PAGES[^=]*=\s*\{(.*?)\n\}", og_py.read_text(encoding="utf-8"), re.S)
    if not ts_m:
        die([f"{site_ts.relative_to(REPO)}: 解析不出 OG_TYPES(静态提取失配,检查写法)"])
    if not py_m:
        die([f"{og_py.relative_to(REPO)}: 解析不出 OG_PAGES(静态提取失配,检查写法)"])
    ts_types = set(re.findall(r"'([\w-]+)'", ts_m.group(1)))
    py_types = set(re.findall(r'^\s{4}"([\w-]+)":', py_m.group(1), re.M))
    if ts_types != py_types:
        errors.append(f"OG 枚举双源漂移:site.ts OG_TYPES {sorted(ts_types)} ≠ "
                      f"build_site_og.py OG_PAGES {sorted(py_types)}(两处必须同步改)")
    expect_og = {f"{t}-{l}.png" for t in (ts_types | py_types) for l in ("en", "zh-hant")}
    actual_og = {p.name for p in (DIST / "og").glob("*.png")} if (DIST / "og").is_dir() else set()
    for name in sorted(expect_og - actual_og):
        errors.append(f"dist/og 缺 {name}(跑 python3 tools/build_site_og.py)")
    for name in sorted(actual_og - expect_og):
        errors.append(f"dist/og 多出孤儿图 {name}(不在 OG_PAGES × 语言全积里)")

    if errors:
        die(errors)
    print(f"check_site_seo: PASS({len(indexable)} indexable 页 / {len(sitemap_urls)} sitemap URL / "
          f"{len(shard_locs)} shard / {len(indexable)} og:image 全 1200x630)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
