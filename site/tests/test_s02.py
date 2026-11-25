#!/usr/bin/env python3
"""S02 验收测试:export 幂等 / 内容校验正负例 / published 缺审构建硬失败 / term_sync 负例。

用法(仓库根):python3 -I site/tests/test_s02.py
说明:
  - 「缺 reviewedBy 却 published」用真实 Astro build 验证(把坏 fixture 放进
    site/src/content → npm build 必须非零 → 清理),对应 S02 验收第 4 条;
  - check_term_sync 负例需要 backend venv(arch -arm64);venv 不可用时 SKIP 并说明。
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SITE = REPO / "site"
FIXTURES = REPO / "site" / "tests" / "fixtures" / "content"
TERMS_JSON = REPO / "site" / "src" / "data" / "terms.json"
BAD_FIXTURE_BODY = """
## 壹|What it describes

This reading is totally accurate and will predict your year with a guarantee; buy a
lucky charm as a remedy, the cure for a bad month, or it can change your fate. The
Direct Officer structure decides everything, it is a textbook 正官格, and destiny is
destined to repeat. See [fixture A](/en/day-master/zz-fixture-a) and the
[library](/en/library), [calculator](/en/bazi-calculator), [app](/en/app),
[about](/en/about), [privacy](/en/privacy), [support](/en/support), [guides](/en/guides),
[today](/en/today) and [fixture B](/en/day-master/zz-fixture-b).
"""

passed: list[str] = []
failed: list[str] = []
skipped: list[str] = []


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600, cwd=str(cwd or REPO))


def record(name: str, ok: bool, detail: str = "") -> None:
    (passed if ok else failed).append(f"{name}{(' — ' + detail) if detail else ''}")
    print(("  ✓ " if ok else "  ✗ ") + name + (f" — {detail}" if detail else ""))


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_export_idempotent() -> None:
    before = sha(TERMS_JSON)
    r1 = run(["python3", "tools/export_site_terms.py"])
    if r1.returncode == 2 and "venv" in r1.stderr.lower():
        skipped.append("export_site_terms 幂等(backend venv 不可用)")
        print("  ⊘ export_site_terms 幂等 — backend venv 不可用,SKIP")
        return
    r2 = run(["python3", "tools/export_site_terms.py"])
    ok = r1.returncode == 0 and r2.returncode == 0 and sha(TERMS_JSON) == before
    record("export_site_terms 幂等(两次运行字节不变)", ok, r1.stderr.strip()[:120] if not ok else "")


def test_compliant_pass() -> None:
    r = run(["python3", "tools/check_site_content.py", "--dir", str(FIXTURES)])
    record("check_site_content 合规 fixtures → PASS", r.returncode == 0, r.stdout.strip()[-160:] if r.returncode else "")


def test_banned_fail_with_location() -> None:
    with tempfile.TemporaryDirectory() as td:
        fixture = Path(td) / "day-master" / "en" / "zz-banned.md"
        fixture.parent.mkdir(parents=True)
        source = (FIXTURES / "day-master" / "en" / "zz-fixture-a.md").read_text(encoding="utf-8")
        # 替换正文(保留合规 frontmatter),注入三类禁词
        source = source[: source.index("\n---\n\n", 4) + 6] + BAD_FIXTURE_BODY
        fixture.write_text(source, encoding="utf-8")
        r = run(["python3", "tools/check_site_content.py", "--dir", td])
        out = r.stdout + r.stderr
        ok = r.returncode == 1 and "zz-banned.md" in out and "禁词命中" in out and any(
            k in out for k in ("注定", "guarantee", "structure", "格")
        )
        record("禁词 fixture → FAIL 且报 文件/行/词类", ok, "" if ok else f"exit={r.returncode} out={out[-300:]}")


def test_dead_link_fail() -> None:
    with tempfile.TemporaryDirectory() as td:
        fixture = Path(td) / "day-master" / "en" / "zz-deadlink.md"
        fixture.parent.mkdir(parents=True)
        source = (FIXTURES / "day-master" / "en" / "zz-fixture-a.md").read_text(encoding="utf-8")
        source = source.replace("[today](/en/today)", "[nothing](/en/day-master/does-not-exist)")
        fixture.write_text(source, encoding="utf-8")
        r = run(["python3", "tools/check_site_content.py", "--dir", td])
        ok = r.returncode == 1 and "死链" in r.stdout and "does-not-exist" in r.stdout
        record("死链 → FAIL 且指出链接", ok, "" if ok else f"exit={r.returncode}")


def test_zodiac_friends_mismatch_fail() -> None:
    """zodiac friends/clash 手填值必须与 terms.json 导出一致;两种形态都要拦:
    块状列表错值 → 逐值比对 FAIL;行内 [未, 寅, 戌](mini-YAML 解析成裸字符串)→ 类型拦截。"""
    base = (FIXTURES / "day-master" / "en" / "zz-fixture-b.md").read_text(encoding="utf-8")
    # 换成 zodiac 形态:branch = 午(terms.json 导出 friends=['未','寅','戌'],clash='子')
    base = re.sub(r"^stem: .*$", "branch: 午\nanimal: Horse", base, count=1, flags=re.M)
    base = re.sub(r"^element: .*$", "element: 火", base, count=1, flags=re.M)
    base = re.sub(r"^polarity: .*$", "polarity: yang", base, count=1, flags=re.M)
    with tempfile.TemporaryDirectory() as td:
        fixture = Path(td) / "zodiac" / "en" / "zz-zodiac-horse.md"
        fixture.parent.mkdir(parents=True)

        def inject(fields: str) -> str:
            # 字段必须插进 frontmatter(第一个 "\n---\n" 是收尾围栏),追加到文件尾只是正文
            return base.replace("\n---\n", "\n" + fields + "---\n", 1)

        # 形态一:块状列表,错值(把戌写成卯)
        fixture.write_text(inject("friends:\n  - 未\n  - 寅\n  - 卯\nclash: 子\n"), encoding="utf-8")
        r = run(["python3", "tools/check_site_content.py", "--dir", td])
        ok1 = r.returncode == 1 and "friends 手填" in r.stdout and "卯" in r.stdout
        # 形态二:行内列表(mini-YAML 解析成裸字符串,必须拦,不许静默跳过)
        fixture.write_text(inject("friends: [未, 寅, 戌]\nclash: 子\n"), encoding="utf-8")
        r = run(["python3", "tools/check_site_content.py", "--dir", td])
        ok2 = r.returncode == 1 and "解析成 str" in r.stdout
        record(
            "zodiac friends 手填错值/行内列表 → FAIL",
            ok1 and ok2,
            "" if (ok1 and ok2) else f"块状错值={ok1} 行内列表={ok2} out={(r.stdout + r.stderr)[-300:]}",
        )


def test_missing_reviewed_by_breaks_build() -> None:
    bad = SITE / "src" / "content" / "day-master" / "en" / "zz-test-unreviewed.md"
    source = (FIXTURES / "day-master" / "en" / "zz-fixture-a.md").read_text(encoding="utf-8")
    # published: true 但删掉 reviewedBy(日期引号无关)
    source, removed = re.subn(r'reviewedBy:\n  date: "?[^"\n]+"?\n  reviewer: "[^"\n]*"\n', "", source)
    assert removed == 1, f"fixture 中找不到 reviewedBy 块可删(模板变了?): {source[:200]}"
    bad.parent.mkdir(parents=True, exist_ok=True)
    bad.write_text(source, encoding="utf-8")
    try:
        r = run(["npm", "run", "build"], cwd=str(SITE))
        record(
            "缺 reviewedBy 却 published → Astro 构建失败(非警告)",
            r.returncode != 0,
            "exit=0(构建居然通过)" if r.returncode == 0 else "build 非零退出 ✓",
        )
        err = r.stdout + r.stderr
        record("构建错误信息点名 reviewedBy", "reviewedBy" in err, "" if "reviewedBy" in err else err[-200:])
    finally:
        bad.unlink(missing_ok=True)
        # 清掉测试 mkdir 出来的空 en/ 目录(git 不追空目录,留着只会给 git clean 添垃圾;
        # 目录非空 = 有他人文件,原样保留)
        if bad.parent.is_dir() and not any(bad.parent.iterdir()):
            bad.parent.rmdir()
        run(["npm", "run", "build"], cwd=str(SITE))  # 恢复绿色构建产物


def test_term_sync_negative() -> None:
    venv = Path("/Users/TWJ/工作/git/QiCompass/backend/.venv/bin/python")
    if not venv.exists():
        skipped.append("term_sync 负例(backend venv 不可用)")
        print("  ⊘ term_sync 负例 — backend venv 不可用,SKIP")
        return
    original = TERMS_JSON.read_text(encoding="utf-8")
    data = json.loads(original)
    group = next(iter(data["groups"]))
    key = next(iter(data["groups"][group]))
    data["groups"][group][key]["en"] = "Drifted Term"
    TERMS_JSON.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        r = run(["arch", "-arm64", str(venv), "tools/check_term_sync.py"])
        ok = r.returncode == 1 and "值漂移" in r.stdout
        record("故意改坏 terms.json en 值 → check_term_sync FAIL", ok, "" if ok else f"exit={r.returncode}")
    finally:
        TERMS_JSON.write_text(original, encoding="utf-8")
    r2 = run(["arch", "-arm64", str(venv), "tools/check_term_sync.py"])
    record("还原后 check_term_sync PASS", r2.returncode == 0, r2.stdout[-120:] if r2.returncode else "")


def main() -> int:
    print("=== S02 验收测试 ===")
    test_export_idempotent()
    test_compliant_pass()
    test_banned_fail_with_location()
    test_dead_link_fail()
    test_zodiac_friends_mismatch_fail()
    test_missing_reviewed_by_breaks_build()
    test_term_sync_negative()
    print(f"=== {len(passed)} 过 / {len(failed)} 败 / {len(skipped)} 跳过 ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
