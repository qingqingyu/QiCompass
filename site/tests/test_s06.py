#!/usr/bin/env python3
"""S06 SEO 基础设施负向/行为测试(site/tests/,test_s02.py 同款直跑风格)。

覆盖 2026-11-28 review 修复面:
  1  checker 正向:对真实 dist PASS
  2  checker 负向:重复 title / hreflang 语言映射错位(子页 + 根级首页) /
     _redirects 幽灵目标 / og:image 语言腿错挂 —— 注入后必须 FAIL 且 exit 1(拒绝而非静默通过)
  3  gen-pair-redirects:正序页必须产出反序别名规则(Codex P1——旧实现只有
     反序文件存在才出规则,用户访问 b-and-a 直接 404)
  4  gen-pair-redirects:未知天干(terms.json 有、STEM_ORDER 没有)→ 抛错退出
  5  OG 枚举双源:site.ts OG_TYPES 塞假类型 → checker 必须报漂移

源文件变更(terms.json / site.ts)均 finally 原文回写;dist 变更全部在临时
副本上做(真实 dist 只读)。
用法(仓库根):python3 -I site/tests/test_s06.py
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SITE = REPO / "site"
DIST = SITE / "dist"
CHECKER = REPO / "tools" / "check_site_seo.py"
GEN_PAIR = SITE / "scripts" / "gen-pair-redirects.mjs"

passed: list[str] = []
failed: list[str] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    (passed if ok else failed).append(name)
    mark = "PASS" if ok else "FAIL"
    print(f"{mark}: {name}" + (f" — {detail}" if detail else ""))


def run(cmd: list[str], cwd: Path = REPO) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def copy_dist(tmp: Path) -> Path:
    d = tmp / "dist"
    shutil.copytree(DIST, d)
    return d


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def write(p: Path, text: str) -> None:
    p.write_text(text, encoding="utf-8")


def checker(dist: Path | None = None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(CHECKER)] + (["--dist", str(dist)] if dist else [])
    return run(cmd)


def main() -> int:
    if not DIST.is_dir():
        print(f"SKIP: dist 不存在({DIST})——先 cd site && npm run build")
        return 0

    # 1 checker 正向
    r = checker()
    record("checker_pass_real_dist", r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "")

    with tempfile.TemporaryDirectory(prefix="kf-s06-") as td:
        tmp = Path(td)

        # 2a 重复 title → FAIL(rc=1 + 点名)
        d = copy_dist(tmp / "a")
        about = read(d / "en" / "about.html")
        m = re.search(r"<title>(.*?)</title>", about, re.S)
        assert m, "fixture: about.html 无 title"
        sup = d / "en" / "support.html"
        write(sup, re.sub(r"<title>.*?</title>", lambda _: f"<title>{m.group(1)}</title>", read(sup), count=1, flags=re.S))
        r = checker(d)
        record("checker_duplicate_title_fail", r.returncode == 1 and "title 与 en/about.html 重复" in r.stdout,
               f"rc={r.returncode}")

        # 2b hreflang 语言映射错位:en 页的 hreflang en 改指 zh-hant 腿(闭合仍过,映射必须抓)
        d = copy_dist(tmp / "b")
        p = d / "en" / "about.html"
        write(p, re.sub(r'(hreflang="en" href="https://knowfate\.app)/en/about', r"\1/zh-hant/about", read(p)))
        r = checker(d)
        record("checker_hreflang_mapping_fail", r.returncode == 1 and "语言映射错位" in r.stdout,
               f"rc={r.returncode}")

        # 2c _redirects 幽灵目标 → FAIL
        d = copy_dist(tmp / "c")
        rd = d / "_redirects"
        write(rd, read(rd) + f"\n/en/about /en/ghost-{td[-6:]} 301\n")
        r = checker(d)
        record("checker_redirect_target_missing_fail", r.returncode == 1 and "目标不存在" in r.stdout,
               f"rc={r.returncode}")

        # 2d og:image 语言腿错挂(en 页引 zh-hant 图,文件存在,尺寸合法——只有语言腿检查能抓)
        d = copy_dist(tmp / "d")
        p = d / "en" / "about.html"
        write(p, re.sub(r'(property="og:image" content="https://knowfate\.app/og/)page-en\.png',
                        r"\1page-zh-hant.png", read(p)))
        r = checker(d)
        record("checker_og_lang_leg_fail", r.returncode == 1 and "语言腿" in r.stdout,
               f"rc={r.returncode}")

        # 2e 首页语言腿错挂(en.html 的 hreflang en 改指 /zh-hant;根级文件无 "en/"
        #    前缀,闭合检查照过——4b 映射检查必须覆盖 en.html/zh-hant.html)
        d = copy_dist(tmp / "d2")
        p = d / "en.html"
        write(p, re.sub(r'(hreflang="en" href="https://knowfate\.app)/en"', r'\1/zh-hant"', read(p)))
        r = checker(d)
        record("checker_home_leg_mapping_fail", r.returncode == 1 and "语言映射错位" in r.stdout,
               f"rc={r.returncode}")

        # 3 正序 pair 页产出反序别名规则(slug 取 terms.json 真实值,不自带第二份表)
        dm = read(SITE / "src" / "lib" / "daymaster.mjs")
        stems = re.findall(r'"([^"]+)"', re.search(r"STEM_ORDER\s*=\s*\[([^\]]*)\]", dm).group(1))
        terms = json.loads(read(SITE / "src" / "data" / "terms.json"))
        s0 = terms["groups"]["heavenlyStems"][stems[0]]["path"].split("/")[-1]
        s1 = terms["groups"]["heavenlyStems"][stems[1]]["path"].split("/")[-1]
        d = copy_dist(tmp / "e")
        comp = d / "en" / "compatibility"
        comp.mkdir(parents=True)
        write(comp / f"{s0}-and-{s1}.html", "<html><body>fixture straight pair page</body></html>")
        r = run(["node", str(GEN_PAIR), "--dist", str(d)], cwd=SITE)
        body = read(d / "_redirects")
        want = f"/en/compatibility/{s1}-and-{s0} /en/compatibility/{s0}-and-{s1} 301"
        record("pair_redirects_reverse_alias_rule", r.returncode == 0 and want in body,
               f"rc={r.returncode} want={want}")

        # 4 未知天干(terms.json 收录、STEM_ORDER 没有)→ 抛错退出,不静默排 -1
        terms_path = SITE / "src" / "data" / "terms.json"
        orig_terms = read(terms_path)
        try:
            mutated = json.loads(orig_terms)
            mutated["groups"]["heavenlyStems"]["虸"] = {"path": "/library/fake-zi-stem"}
            write(terms_path, json.dumps(mutated, ensure_ascii=False, indent=2))
            r = run(["node", str(GEN_PAIR), "--dist", str(d)], cwd=SITE)
            record("pair_redirects_unknown_stem_throw",
                   r.returncode != 0 and "不在 STEM_ORDER" in r.stderr + r.stdout,
                   f"rc={r.returncode}")
        finally:
            write(terms_path, orig_terms)

    # 5 OG 枚举双源漂移(site.ts 塞假类型 → checker 报漂移;真实 dist,源级检查)
    ts = SITE / "src" / "data" / "site.ts"
    orig_ts = read(ts)
    try:
        write(ts, re.sub(r"(OG_TYPES\s*=\s*\[)", r"\1'zzz-fake', ", orig_ts))
        r = checker()
        record("checker_og_types_drift_fail", r.returncode == 1 and "OG 枚举双源漂移" in r.stdout,
               f"rc={r.returncode}")
    finally:
        write(ts, orig_ts)

    # 复原自检:源回写后 checker 对真实 dist 回绿
    r = checker()
    record("checker_restored_green", r.returncode == 0, f"rc={r.returncode}")

    print(f"\ns06: {len(passed)} passed, {len(failed)} failed")
    if failed:
        for f in failed:
            print(f"  FAILED: {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
