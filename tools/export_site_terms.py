#!/usr/bin/env python3
"""导出官网术语表:backend term_translations.py → site/src/data/terms.json(S02 #1)。

单一事实源:术语译名一律取 backend 表。词表提取用 **AST 静态解析**(不 import
backend 模块——term_translations 经 chart_builder 拖起 pydantic,而本机系统
python3(x86_64)装不上 arm64 的 pydantic_core;AST 解析让本脚本在任意 python 下
可跑,与 build_site_fonts.py 的纯文本扫描同哲学)。表结构变化(ast.literal_eval
失败/键集合与 zh-hant 表不等)→ 直接 FAIL,不用默认值兜底。

branchRelations 不静态解析:六合/三合/六冲 + 组合逻辑是行为不是数据,复制会漂移。
改用 subprocess 调 backend venv(arch -arm64)执行 compute_friends_and_clash——
与 check_term_sync.py 现状一致的 venv 依赖;venv 缺失/架构不符 → FAIL(显式传播)。
check_term_sync ⑤ 组另做 terms.json ↔ backend 交叉校验闭环(防手改 JSON)。

slug 推导(站点 URL 约定,规格 README §3;派生规则写死在此,是站点的唯一出处):
  heavenlyStems  /day-master/{pinyin}-{element}   (GAN_ELEMENT 静态解析自 pillars.py)
  tenGods        /ten-gods/{en slugify}           (偏官 alias 与 七杀 同页,合法)
  fiveElements   /five-elements/{en}
  shensha        /stars/{en slugify}
  earthlyBranches /zodiac/{pinyin}(临时;生肖动物名不在 backend 表内,S11 导出时改挂 animal slug)
  nayin / twelveStages 无独立页(path = null;S11 日柱页/术语页建好后由该 slice 接管)

输出进 git(构建机/Astro 无需 Python);确定性:同输入 → 同字节(键序 = backend
源码字典序,即干支/神煞的正典顺序)。

用法(仓库根):
  python3 tools/export_site_terms.py        # 写 site/src/data/terms.json + 幂等自检
退出码:0 成功;2 脚本错误(backend 表缺失/结构变化/venv 不可用)。
"""
from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
OUT = ROOT / "site" / "src" / "data" / "terms.json"


def resolve_venv_python() -> Path:
    """backend venv python:先找本仓,worktree 里回退主仓(venv 不进 git,只在主仓存在)。"""
    candidates = [BACKEND / ".venv" / "bin" / "python"]
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip()
        candidates.append(Path(common).parent / "backend" / ".venv" / "bin" / "python")
    except (subprocess.SubprocessError, OSError):
        pass  # 非 git 环境只看本仓
    for c in candidates:
        if c.exists():
            return c
    raise ValueError(
        "backend venv python 找不到(试过 " + "; ".join(str(c) for c in candidates) + ");"
        "branchRelations 需要它调后端权威逻辑(worktree 场景见 CLAUDE.md「evalkit 要领」)"
    )


VENV_PY = resolve_venv_python()

TERM_TRANS = BACKEND / "app" / "engine" / "term_translations.py"
PILLARS = BACKEND / "app" / "engine" / "pillars.py"

# 术语组:(组名, en 表名, zh-hant 表名, 页面路径模板;None = 无独立页)
GROUPS: list[tuple[str, str, str, str | None]] = [
    ("heavenlyStems", "HEAVENLY_STEMS_EN", "HEAVENLY_STEMS_ZH_HANT", "/day-master/{slug}"),
    ("earthlyBranches", "EARTHLY_BRANCHES_EN", "EARTHLY_BRANCHES_ZH_HANT", "/zodiac/{slug}"),
    ("fiveElements", "FIVE_ELEMENTS_EN", "FIVE_ELEMENTS_ZH_HANT", "/five-elements/{slug}"),
    ("tenGods", "TEN_GODS_EN", "TEN_GODS_ZH_HANT", "/ten-gods/{slug}"),
    ("nayin", "NAYIN_EN", "NAYIN_ZH_HANT", None),
    ("twelveStages", "TWELVE_STAGES_EN", "TWELVE_STAGES_ZH_HANT", None),
    ("shensha", "SHENSHA_EN", "SHENSHA_ZH_HANT", "/stars/{slug}"),
]


def extract_dict_literal(path: Path, var_name: str) -> dict[str, str]:
    """从 .py 源码 AST 提取顶层 `VAR: Final[dict[str, str]] = {...}` 字符串字典。"""
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            targets = [node.target.id]
        else:
            continue
        if var_name in targets and node.value is not None:
            try:
                value = ast.literal_eval(node.value)
            except (ValueError, SyntaxError) as e:
                raise ValueError(f"{path.name}:{var_name} 不是纯字面量(AST 解析失败): {e}") from e
            if not isinstance(value, dict) or not all(
                isinstance(k, str) and isinstance(v, str) for k, v in value.items()
            ):
                raise ValueError(f"{path.name}:{var_name} 不是 str→str 字典")
            return value
    raise ValueError(f"{path.name} 找不到 {var_name}(backend 表改名了?)")


def extract_gan_element() -> dict[str, str]:
    return extract_dict_literal(PILLARS, "GAN_ELEMENT")


def extract_branch_relations_tables() -> tuple[frozenset, tuple, frozenset, dict[str, int]]:
    """branch_relations.py 的 LIUHE / SANHE / LIUCHONG / ZHI_ORDER(校验 ⑤ 组用后端直算,此处仅兜底导出)。"""
    tree = ast.parse(
        (BACKEND / "app" / "engine" / "branch_relations.py").read_text(encoding="utf-8"),
        filename="branch_relations.py",
    )
    found: dict[str, object] = {}
    for node in tree.body:
        names = []
        if isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names = [node.target.id]
        for n in ("LIUHE", "SANHE", "LIUCHONG", "ZHI_ORDER"):
            if n in names and node.value is not None:
                found[n] = ast.literal_eval(node.value)
    missing = {"LIUHE", "SANHE", "LIUCHONG", "ZHI_ORDER"} - set(found)
    if missing:
        raise ValueError(f"branch_relations.py 缺常量: {sorted(missing)}")
    return found["LIUHE"], found["SANHE"], found["LIUCHONG"], found["ZHI_ORDER"]


def backend_branch_relations(venv_py: Path) -> dict[str, dict]:
    """经 backend venv 调 compute_friends_and_clash(权威逻辑,不复制算法)。"""
    code = (
        "import json,sys; sys.path.insert(0, %r); "
        "from app.engine.branch_relations import compute_friends_and_clash; "
        "print(json.dumps({z: dict(zip(('friends','clash'), compute_friends_and_clash(z))) "
        "for z in '子丑寅卯辰巳午未申酉戌亥'}, ensure_ascii=False))"
    ) % str(BACKEND)
    try:
        proc = subprocess.run(
            ["arch", "-arm64", str(VENV_PY), "-c", code],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ValueError(f"backend venv 调用失败: {e}") from e
    if proc.returncode != 0:
        raise ValueError(f"backend compute_friends_and_clash 失败: {proc.stderr.strip()[-400:]}")
    data = json.loads(proc.stdout)
    if set(data) != set("子丑寅卯辰巳午未申酉戌亥") or any(
        len(v["friends"]) != 3 for v in data.values()
    ):
        raise ValueError("backend branchRelations 结构异常(应 12 支 × friends 3)")
    return data


def slugify(en: str) -> str:
    """英文译名 → URL slug(小写、非字母数字转连字符)。确定性纯函数。"""
    slug = re.sub(r"[^a-z0-9]+", "-", en.lower()).strip("-")
    if not slug:
        raise ValueError(f"slugify 产出空串: {en!r}")
    return slug


def build_terms() -> dict:
    gan_element = extract_gan_element()
    groups: dict[str, dict] = {}
    for name, en_name, hant_name, pattern in GROUPS:
        en_table = extract_dict_literal(TERM_TRANS, en_name)
        hant_table = extract_dict_literal(TERM_TRANS, hant_name)
        if set(en_table) != set(hant_table):
            raise ValueError(
                f"backend 表 {name} en/zh-hant 键集合不等(en={len(en_table)}, hant={len(hant_table)})"
            )
        group: dict[str, dict] = {}
        slug_owners: dict[str, str] = {}
        for zh, en in en_table.items():
            if name == "heavenlyStems":
                element = gan_element.get(zh)
                if element is None:
                    raise ValueError(f"GAN_ELEMENT 缺天干 {zh!r}(backend pillars.py 变了?)")
                slug = f"{slugify(en)}-{element}"       # 甲 → jia-wood(规格 §3 天干不单独建页)
            elif pattern is None:
                slug = None
            else:
                slug = slugify(en)
            if slug is not None:
                owner = slug_owners.setdefault(slug, zh)
                if owner != zh and en_table[owner] != en:
                    # 同 slug = 同页(偏官/七杀 同到 seven-killings)是合法 alias;
                    # en 不同还撞 slug 才是推导 bug
                    raise ValueError(f"组 {name} slug 撞车且非同义词: {slug!r}({owner}/{zh})")
            group[zh] = {
                "en": en,
                "zhHant": hant_table[zh],
                "path": pattern.replace("{slug}", slug) if (pattern and slug) else None,
            }
        groups[name] = group

    groups["branchRelations"] = backend_branch_relations(VENV_PY)
    return {
        "_meta": {
            "source": "backend/app/engine/term_translations.py(AST 静态解析)+ pillars.py GAN_ELEMENT"
                      " + branch_relations.py compute_friends_and_clash(venv subprocess)",
            "generator": "tools/export_site_terms.py",
            "order": "键序 = backend 源码字典序(干支/神煞正典顺序);勿手改,重跑生成器",
            "branchNote": "earthlyBranches.path 临时挂地支拼音;生肖动物名不在 backend 表内,S11 导出时改挂 animal slug",
        },
        "groups": groups,
    }


def main() -> int:
    data = build_terms()

    # 幂等自检:双跑字节相等
    rendered = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    with tempfile.TemporaryDirectory() as td:
        second = Path(td) / "terms.json"
        second.write_text(json.dumps(build_terms(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if second.read_text(encoding="utf-8") != rendered:
            print("FAIL: 导出非幂等(两次构建字节不同)", file=sys.stderr)
            return 2

    OUT.write_text(rendered, encoding="utf-8")
    counts = {k: len(v) for k, v in data["groups"].items()}
    print(f"已写入 {OUT.relative_to(ROOT)}:{json.dumps(counts, ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError) as e:
        print(f"FAIL(脚本错误/backend 结构变化): {e}", file=sys.stderr)
        sys.exit(2)
