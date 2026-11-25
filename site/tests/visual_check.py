#!/usr/bin/env python3
"""S01 验收测试(Playwright):canonical/hreflang、无 Google Fonts、关 JS 可读、
390px 无横向滚动、reduced-motion 降级、亮暗双主题截图。

用法(仓库根或 site/):
  python3 site/tests/visual_check.py --dist site/dist --out site/tests/screenshots

浏览器:环境预装的 playwright 包 + ms-playwright 缓存里已有的 Chrome for Testing
(不执行 playwright install;可用 --executable 显式指定)。
"""
from __future__ import annotations

import argparse
import http.server
import os
import socketserver
import sys
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parent.parent.parent
PAGES = ["/en/", "/zh-hant/", "/en/kitchen-sink", "/zh-hant/kitchen-sink"]
SCREEN_PAGES = ["/en/kitchen-sink", "/zh-hant/kitchen-sink"]

# JS 关闭后等 CSS 动画(ink-in 1.4s + 最长 delay .75s)走完
ANIMATION_SETTLE_MS = 2600

JS_OPACITY_CHECK = """
() => {
  const bad = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const seen = new Set();
  while (walker.nextNode()) {
    const text = walker.currentNode;
    if (!text.textContent.trim()) continue;
    const el = text.parentElement;
    if (!el || seen.has(el)) continue;
    seen.add(el);
    const cs = getComputedStyle(el);
    const hidden = cs.display === 'none' || cs.visibility === 'hidden';
    if (!hidden && parseFloat(cs.opacity) < 0.5) {
      bad.push({ tag: el.tagName, cls: el.className && el.className.toString().slice(0, 60),
                 opacity: cs.opacity, text: text.textContent.trim().slice(0, 40) });
    }
  }
  return bad;
}
"""

REDUCED_MOTION_CHECK = """
() => {
  const problems = [];
  document.querySelectorAll('.ink-in').forEach((el) => {
    if (getComputedStyle(el).filter !== 'none') {
      problems.push('ink-in blur not cleared: ' + (el.className || '').toString().slice(0, 60));
    }
  });
  document.querySelectorAll('.enso.draw path.stroke').forEach((el) => {
    const cs = getComputedStyle(el);
    if (cs.animationName !== 'none' && cs.animationName !== '') {
      problems.push('enso draw animation still set: ' + cs.animationName);
    }
    if (parseFloat(cs.strokeDashoffset) !== 0) {
      problems.push('enso strokeDashoffset not 0: ' + cs.strokeDashoffset);
    }
  });
  return problems;
}
"""


def find_executable(explicit: str | None) -> str:
    if explicit:
        return explicit
    cache = Path.home() / "Library" / "Caches" / "ms-playwright"
    candidates = sorted(cache.glob("chromium-*/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"))
    if candidates:
        return str(candidates[-1])
    chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if chrome.exists():
        return str(chrome)
    raise SystemExit("FAIL: 找不到可用的 Chromium(用 --executable 指定)")


def serve(dist: Path, port: int):
    handler = lambda *args, **kw: http.server.SimpleHTTPRequestHandler(*args, directory=str(dist), **kw)
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def parse_head(page) -> dict:
    return page.evaluate(
        """() => {
        const links = [...document.querySelectorAll('head link[rel]')];
        return {
          canonical: links.filter(l => l.rel === 'canonical').map(l => l.href),
          hreflang: links.filter(l => l.rel === 'alternate' && l.hreflang)
                         .map(l => ({ lang: l.hreflang, href: l.href })),
          robots: document.querySelector('meta[name="robots"]')?.content || null,
          title: document.title,
          description: document.querySelector('meta[name="description"]')?.content || null,
          htmlLang: document.documentElement.lang,
        };
      }"""
    )


def check_page(head: dict, url_path: str) -> list[str]:
    # 产物里的 canonical/hreflang 是生产域绝对 URL(https://knowfate.app/...),
    # 本地起的是 127.0.0.1 —— 只比对 path,域断言交给产物 grep(全站必须 knowfate.app)。
    from urllib.parse import urlparse

    problems: list[str] = []
    if len(head["canonical"]) != 1:
        problems.append(f"{url_path}: canonical 数量 {len(head['canonical'])}(应为 1)")
    canonical_path = urlparse(head["canonical"][0]).path if head["canonical"] else None
    # 兄弟页 = 整段换语言前缀(kitchen-sink ↔ kitchen-sink;语言根 ↔ 语言根)
    rest = url_path.removeprefix("/en").removeprefix("/zh-hant").rstrip("/")
    expect_en = "/en" + rest
    expect_hant = "/zh-hant" + rest
    hreflang = {h["lang"]: urlparse(h["href"]).path for h in head["hreflang"]}
    if set(hreflang) != {"en", "zh-Hant", "x-default"}:
        problems.append(f"{url_path}: hreflang 键 {sorted(hreflang)}")
    else:
        if hreflang["en"] != expect_en or hreflang["x-default"] != expect_en:
            problems.append(f"{url_path}: hreflang en/x-default 应为 {expect_en},实际 {hreflang['en']}/{hreflang['x-default']}")
        if hreflang["zh-Hant"] != expect_hant:
            problems.append(f"{url_path}: hreflang zh-Hant 应为 {expect_hant},实际 {hreflang['zh-Hant']}")
    if canonical_path not in (expect_en, expect_hant):
        problems.append(f"{url_path}: canonical path {canonical_path} 与路径不符")
    if head["canonical"] and urlparse(head["canonical"][0]).netloc != "knowfate.app":
        problems.append(f"{url_path}: canonical 域名应为 knowfate.app")
    if not head["description"]:
        problems.append(f"{url_path}: 缺 meta description")
    expect_html_lang = "zh-Hant" if url_path.startswith("/zh-hant") else "en"
    if head["htmlLang"] != expect_html_lang:
        problems.append(f"{url_path}: html lang = {head['htmlLang']},应为 {expect_html_lang}")
    is_sink = "kitchen-sink" in url_path
    if is_sink and head["robots"] != "noindex, nofollow":
        problems.append(f"{url_path}: 示例页应有 robots noindex,实际 {head['robots']!r}")
    if not is_sink and head["robots"] not in (None, "index, follow"):
        problems.append(f"{url_path}: 正常页不应 noindex,实际 {head['robots']!r}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dist", default=str(REPO / "site" / "dist"))
    parser.add_argument("--out", default=str(REPO / "site" / "tests" / "screenshots"))
    parser.add_argument("--port", type=int, default=8931)
    parser.add_argument("--executable", default=None)
    args = parser.parse_args()

    dist = Path(args.dist).resolve()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if not (dist / "index.html").exists() and not (dist / "en").exists():
        raise SystemExit(f"FAIL: {dist} 不是构建产物(先 npm run build)")

    base = f"http://127.0.0.1:{args.port}"
    httpd = serve(dist, args.port)
    problems: list[str] = []

    try:
        with sync_playwright() as p:
            exe = find_executable(args.executable)
            browser = p.chromium.launch(executable_path=exe)

            # ---------- 1. 静态断言(head/robots/Google Fonts)+ 390px 横向滚动 ----------
            for page_path in PAGES:
                ctx = browser.new_context(viewport={"width": 390, "height": 844})
                page = ctx.new_page()
                page.goto(base + page_path, wait_until="networkidle")
                head = parse_head(page)
                problems += check_page(head, page_path)

                # Google Fonts 任何形式的外链都不允许(networkidle 已含 CSS/字体请求;
                # 这里再查 DOM 与请求双保险)
                html = page.content()
                if "fonts.googleapis.com" in html or "fonts.gstatic.com" in html:
                    problems.append(f"{page_path}: 产物含 Google Fonts 引用")

                sw = page.evaluate("() => document.scrollingElement.scrollWidth")
                if sw != 390:
                    problems.append(f"{page_path}: 390px 下 scrollWidth={sw}(应恰好 390,无横向滚动)")

                # 字体确实加载了(自托管生效):title 用的 Newsreader / 中文用 QiSongti Web
                fonts = page.evaluate(
                    "async () => { await document.fonts.ready;"
                    " return { nr: document.fonts.check('20px Newsreader'),"
                    " zh: document.fonts.check('20px \"QiSongti Web\"') || document.fonts.check('20px \"QiSongti Web TC\"') }; }"
                )
                if not fonts["nr"]:
                    problems.append(f"{page_path}: Newsreader 未加载")
                if not fonts["zh"]:
                    problems.append(f"{page_path}: 中文子集未加载(QiSongti Web / Web TC)")
                ctx.close()

            # ---------- 2. 关 JS 可读性 ----------
            for page_path in SCREEN_PAGES:
                ctx = browser.new_context(java_script_enabled=False, viewport={"width": 1440, "height": 900})
                page = ctx.new_page()
                page.goto(base + page_path, wait_until="load")
                page.wait_for_timeout(ANIMATION_SETTLE_MS)
                bad = page.evaluate(JS_OPACITY_CHECK)
                if bad:
                    problems.append(f"{page_path}[no-JS]: {len(bad)} 个文本节点 opacity<0.5: {bad[:5]}")
                ctx.close()

            # ---------- 3. reduced-motion 降级 ----------
            for page_path in SCREEN_PAGES:
                ctx = browser.new_context(reduced_motion="reduce", viewport={"width": 1440, "height": 900})
                page = ctx.new_page()
                page.goto(base + page_path, wait_until="networkidle")
                page.wait_for_timeout(600)
                bad = page.evaluate(REDUCED_MOTION_CHECK)
                if bad:
                    problems.append(f"{page_path}[reduced-motion]: {bad[:5]}")
                ctx.close()

            # ---------- 4. 截图(1440/390 × 亮/暗) ----------
            for page_path in SCREEN_PAGES:
                slug = page_path.strip("/").replace("/", "-")
                for width, height, tag in [(1440, 900, "desktop"), (390, 844, "mobile")]:
                    for scheme in ["light", "dark"]:
                        ctx = browser.new_context(viewport={"width": width, "height": height}, color_scheme=scheme)
                        page = ctx.new_page()
                        page.goto(base + page_path, wait_until="networkidle")
                        page.wait_for_timeout(ANIMATION_SETTLE_MS)
                        page.screenshot(path=str(out / f"{slug}-{tag}-{scheme}.png"), full_page=True)
                        ctx.close()
            browser.close()
    finally:
        httpd.shutdown()

    if problems:
        print("FAIL:", file=sys.stderr)
        for pr in problems:
            print(" -", pr, file=sys.stderr)
        return 1
    print(f"PASS — {len(PAGES)} 页断言全过;截图已写入 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
