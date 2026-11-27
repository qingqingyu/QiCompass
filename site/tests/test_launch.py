#!/usr/bin/env python3
"""TASK-18 验收测试(2026-11-27):上线开关单一事实源 site/src/data/launch.json。

用法(仓库根):python3 -I site/tests/test_launch.py
组成:
  1. 向量 parity:Python 侧 is_launched(tools/check_site_content.py)与 Node 侧
     matchSection(site/src/data/launch.mjs,由 launch.test.mjs 断言)共读
     site/tests/fixtures/launch-cases.json,同一组向量锁两侧实现行为一致;
  2. 真实 launch.json 结构校验(与 checker 同一入口,结构不符 = exit 2 路径);
  3. 草稿死链翻转:published:false 的页被已发布页内链 → checker FAIL,
     翻成 published:true → PASS(临时目录夹具,不碰真实 content/;草稿放
     zodiac-year/ 收集——launch.json 无该区块,恒视为已上线,翻转测试不受
     真实开关状态影响);
  4. 开关一致性:「只开 calculator」「全关」两种组合各构建一次,页头与页脚
     中 /bazi-calculator 出链状态必须一致(临时改真实 launch.json,finally
     还原)。calculator 自 S05 起默认开启,「全关」相是显式写入 false 的测试
     态而非默认态——测试结束后须重跑默认 build 再做依赖 dist 的校验。
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SITE = REPO / "site"
FIXTURES = REPO / "site" / "tests" / "fixtures" / "content"
LAUNCH_CASES = REPO / "site" / "tests" / "fixtures" / "launch-cases.json"
LAUNCH_JSON = REPO / "site" / "src" / "data" / "launch.json"

# 翻转测试的草稿夹具:frontmatter 须同时满足「草稿」与「翻转成已发布」两侧的
# 校验(published 规则全量:description 长度 / faq 2–4 / reviewedBy / 内链 ≥8
# 且全部可解析——只链语言根与 kitchen-sink,任何开关组合下都在线上)。
DRAFT_C_BODY = """
## 壹|Draft fixture

This page begins as a draft. Start from the [home page](/en), the [Chinese home](/zh-hant),
and the twin [style guide](/en/kitchen-sink) and [樣式總覽](/zh-hant/kitchen-sink) pages;
the [English home](/en) and [Chinese home](/zh-hant) links repeat so the page always carries
at least eight internal links, and the [style guides](/en/kitchen-sink) and
[繁體樣式總覽](/zh-hant/kitchen-sink) links stay resolvable once published.
"""

DRAFT_C = f"""---
title: "Zodiac-year draft fixture C"
description: "Zodiac-year fixture page for the launch-switch tests: it stays a draft until the flip test publishes it, then every internal link below must resolve."
slug: zz-draft-c
lang: en
inShort: "Draft fixture for the launch-switch flip test."
updated: "2026-11-27"
published: false
reviewedBy:
  date: "2026-11-27"
  reviewer: "TASK-18 双 review"
faq:
  - q: "Why does this page exist?"
    a: "It backs the draft dead-link flip test for the content checker."
  - q: "Is it shipped to the site?"
    a: "No. It lives only under site/tests/fixtures and stays a draft."
---

{DRAFT_C_BODY}"""

passed: list[str] = []
failed: list[str] = []


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600, cwd=str(cwd or REPO))


def record(name: str, ok: bool, detail: str = "") -> None:
    (passed if ok else failed).append(f"{name}{(' — ' + detail) if detail else ''}")
    print(("  ✓ " if ok else "  ✗ ") + name + (f" — {detail}" if detail else ""))


def load_checker():
    """按路径加载 tools/check_site_content.py,直接测生产函数(不另写镜像)。"""
    spec = importlib.util.spec_from_file_location(
        "check_site_content", REPO / "tools" / "check_site_content.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_launch_cases_python_side() -> None:
    checker = load_checker()
    fixture = json.loads(LAUNCH_CASES.read_text(encoding="utf-8"))
    bad: list[str] = []
    for c in fixture["cases"]:
        sections = {
            name: {"enabled": name in c["enabled"], "prefixes": sec["prefixes"]}
            for name, sec in fixture["sections"].items()
        }
        got = checker.is_launched(c["rest"], sections)
        if got != c["expect"]:
            bad.append(f"{c['name']}(rest={c['rest']}) 得 {got}")
    record(
        f"launch-cases ×{len(fixture['cases'])} → Python is_launched 全对",
        not bad, "; ".join(bad),
    )


def test_real_launch_json_structure() -> None:
    checker = load_checker()
    try:
        sections = checker.load_launch_sections()
        ok = isinstance(sections, dict) and bool(sections)
        detail = "" if ok else "load_launch_sections 返回空"
    except RuntimeError as e:
        ok, detail = False, str(e)
    record("真实 launch.json 结构校验(与 checker 同一入口)PASS", ok, detail)


def test_draft_link_flip() -> None:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        content = tmp / "content"
        shutil.copytree(FIXTURES, content)
        draft_dir = content / "zodiac-year" / "en"
        draft_dir.mkdir(parents=True)
        draft = draft_dir / "zz-draft-c.md"
        draft.write_text(DRAFT_C, encoding="utf-8")
        # 已发布页(夹具 A 的临时副本)追加一条指向草稿的内链 → 死链 → FAIL
        a = content / "day-master" / "en" / "zz-fixture-a.md"
        a.write_text(
            a.read_text(encoding="utf-8") + "\n[Draft sibling](/en/zodiac-year/zz-draft-c)\n",
            encoding="utf-8",
        )
        r1 = run(["python3", "tools/check_site_content.py", "--dir", str(content)])
        ok1 = r1.returncode == 1 and "死链" in r1.stdout and "zz-draft-c" in r1.stdout
        # 翻成 published:true → 路由成立 → 同一批夹具 PASS
        draft.write_text(
            draft.read_text(encoding="utf-8").replace("published: false", "published: true"),
            encoding="utf-8",
        )
        r2 = run(["python3", "tools/check_site_content.py", "--dir", str(content)])
        ok2 = r2.returncode == 0
        record(
            "草稿被已发布页内链 → FAIL;翻 published:true → PASS",
            ok1 and ok2,
            "" if ok1 and ok2 else (
                f"FAIL段 exit={r1.returncode} 含死链报错={('死链' in r1.stdout) and ('zz-draft-c' in r1.stdout)}; "
                f"PASS段 exit={r2.returncode} out={(r2.stdout + r2.stderr)[-240:]}"
            ),
        )


def _href_parts(html: str, href: str) -> tuple[bool, bool]:
    """页头出链 = </nav> 之前的部分;页脚出链 = <footer 之后的部分。"""
    header_part = html.split("</nav>", 1)[0]
    footer_part = html.split("<footer", 1)[1] if "<footer" in html else ""
    return (href in header_part, href in footer_part)


def test_header_footer_consistency() -> None:
    original = LAUNCH_JSON.read_text(encoding="utf-8")
    try:
        # 顺序先「只开 calculator」后「全关」:结束时 dist 停在 calculator 关闭的
        # 产物。两相都以显式开关写入:calculator 自 S05 起默认为 true,「全关」相
        # 不能原样还原(会把默认的 true 带进断言「出链消失」的一相,假红);
        # 因此「全关」是测试态而非默认态,测试后依赖 dist 的校验前须重跑默认 build。
        for label, calc_on in (("只开 calculator", True), ("全关(显式关闭)", False)):
            data = json.loads(original)
            data["sections"]["calculator"]["enabled"] = calc_on
            LAUNCH_JSON.write_text(
                json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            r = run(["npm", "run", "build"], cwd=str(SITE))
            ok = r.returncode == 0
            detail = f"build exit={r.returncode}"
            if ok:
                for lang in ("en", "zh-hant"):
                    html = (SITE / "dist" / f"{lang}.html").read_text(encoding="utf-8")
                    in_header, in_footer = _href_parts(html, f"/{lang}/bazi-calculator")
                    if calc_on:
                        ok = ok and in_header and in_footer
                        detail += f"; {lang} header✓={in_header} footer✓={in_footer}"
                    else:
                        ok = ok and not in_header and not in_footer
                        detail += f"; {lang} header灰={not in_header} footer灰={not in_footer}"
            record(f"页头/页脚 /bazi-calculator 出链一致({label})", ok, detail)
    finally:
        LAUNCH_JSON.write_text(original, encoding="utf-8")


def main() -> int:
    print("=== TASK-18 验收测试(launch.json 单一事实源) ===")
    test_launch_cases_python_side()
    test_real_launch_json_structure()
    test_draft_link_flip()
    test_header_footer_consistency()
    print(f"=== {len(passed)} 过 / {len(failed)} 败 ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
