#!/usr/bin/env python3
"""官网内容校验(S02 #5)——内容生产闸门,每次动 site/src/content 后必跑。

规则(规格 README §8 内容红线 + S02):
  1. 禁词:backend forbidden_words.scan(绝对化结论)+ 额外英文禁词
     (accurate / predict 家族 / guarantee / lucky charm / cure / remedy /
     change your fate)+ 格局硬分类(十神/五行 en 名 + "structure" 结论式;
     中文「正官格 / 偏印格 / ……格」。从格/专旺是 App 诚实降级概念,**不**禁)
  2. frontmatter:必填字段、长度规则(title ≤60 / description 140–160 /
     inShort en ≤60 词或中文 ≤120 字 / faq 2–4)、lang 与目录一致、
     slug 与文件名一致且唯一、reviewedBy 非空才可 published: true
  3. 内链:每页正文站内链接 ≥ 8 条,且全部指向存在的路由
     (内容页路由由 content/** 推导;固定路由 = 站点骨架页清单)
  4. zodiac 的 friends/clash 若手填,必须与 terms.json branchRelations 一致
  5. 关键字段取值必须在 terms.json 对应组内(stem/god/star/element/branch)

用法(仓库根):
    python3 tools/check_site_content.py                 # 校验 site/src/content
    python3 tools/check_site_content.py --dir <dir>     # 校验测试 fixtures
退出码:0 = PASS;1 = 内容 FAIL;2 = 脚本自身错误。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
CONTENT = ROOT / "site" / "src" / "content"
TERMS_JSON = ROOT / "site" / "src" / "data" / "terms.json"
COLLECTIONS = ("day-master", "ten-gods", "five-elements", "stars", "guides", "zodiac", "zodiac-year")
CJK_RE = re.compile(r"[　-鿿豈-﫿]")

sys.path.insert(0, str(BACKEND))
from app.ai.forbidden_words import scan as backend_scan  # noqa: E402  (纯词表扫描,无 pydantic 依赖)

# ---------- 额外禁词(S02 规格明文;英文整词边界,大小写不敏感) ----------
EXTRA_EN_BANNED = [
    (r"\baccurate\b", "accurate"),
    (r"\bpredict(?:ion|ions|ive|able|ably|s|ed|ing)?\b", "predict(ion)"),
    (r"\bguarantee(?:d|s)?\b", "guarantee"),
    (r"\blucky\s+charms?\b", "lucky charm"),
    (r"\bcure(?:d|s)?\b", "cure"),
    (r"\bremed(?:y|ies)\b", "remedy"),
    (r"\bchange\s+your\s+fate\b", "change your fate"),
]
# 格局硬分类:十神/五行 en 名 + "structure" 作为结论式;从格/专旺(诚实降级)不在列
_TEN_GOD_EN = [
    "Companion", "Rob Wealth", "Eating God", "Hurting Officer",
    "Indirect Wealth", "Direct Wealth", "Direct Officer", "Seven Killings",
    "Direct Resource", "Indirect Resource",
]
_STRUCTURE_BANNED = re.compile(
    r"\b(?:" + "|".join(re.escape(n) for n in _TEN_GOD_EN)
    + r"|Wood|Fire|Earth|Metal|Water)\s+structure\b"
)
# 中文格局硬分类(十神格 + 常见外格;「从格」「专旺」是 App 诚实降级概念,不禁)
GE_ZH_BANNED = re.compile(
    r"(?:正官|偏官|七杀|七殺|正财|正財|偏财|偏財|正印|偏印|食神|伤官|傷官|比肩|劫财|劫財|"
    r"建禄|建祿|羊刃|魁罡|曲直|炎上|稼穑|稼穡|从革|從革|润下|潤下|从儿|從兒|从旺|從旺|化气|化氣)格"
)

# 站点骨架固定路由(与 Header/Footer/nav 常量同步;内容页只许链这些 + 其他内容页)
KNOWN_STATIC_ROUTES = {
    "/", "/en", "/zh-hant",
    "/en/bazi-calculator", "/zh-hant/bazi-calculator",
    "/en/library", "/zh-hant/library",
    "/en/guides", "/zh-hant/guides",
    "/en/today", "/zh-hant/today",
    "/en/app", "/zh-hant/app",
    "/en/about", "/zh-hant/about",
    "/en/privacy", "/zh-hant/privacy",
    "/en/support", "/zh-hant/support",
    "/en/kitchen-sink", "/zh-hant/kitchen-sink",
}

# ---------- 迷你 YAML 解析(只支持 CONTENT_GUIDE.md 约定的形态;越界即报错) ----------


class YamlError(Exception):
    pass


def _parse_scalar(raw: str, line_no: int):
    raw = raw.strip()
    if raw == "":
        raise YamlError(f"行 {line_no}: 期望值,得到空")
    if raw == "[]":
        return []
    if raw.startswith('"'):
        if not raw.endswith('"') or len(raw) < 2:
            raise YamlError(f"行 {line_no}: 引号字符串未闭合: {raw[:40]!r}")
        return raw[1:-1].replace('\\"', '"')
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw  # 裸字符串(日期 / slug / 汉字)


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """解析 `--- … ---` frontmatter;返回 (数据, 正文)。

    只支持指南约定形态:标量 / 一层嵌套 dict / 字符串列表 / 两键 dict 列表。
    其他形态 → YamlError(调用方按内容 FAIL 报出)。
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise YamlError("第 1 行必须是 ---")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise YamlError("frontmatter 未闭合(缺结束 ---)") from None

    data: dict = {}
    i = 1
    while i < end:
        line = lines[i]
        line_no = i + 1
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if line.startswith((" ", "\t")):
            raise YamlError(f"行 {line_no}: 意外缩进(顶层键必须顶格)")
        m = re.match(r"^([A-Za-z][A-Za-z0-9]*):\s*(.*)$", stripped)
        if not m:
            raise YamlError(f"行 {line_no}: 无法解析的行: {stripped[:50]!r}")
        key, inline = m.group(1), m.group(2)
        if key in data:
            raise YamlError(f"行 {line_no}: 顶层键重复: {key}")
        if inline:
            data[key] = _parse_scalar(inline, line_no)
            i += 1
            continue
        # 块值:一层 dict / 字符串列表 / 两键 dict 列表
        j = i + 1
        child: list | dict | None = None
        list_item: dict | None = None
        while j < end:
            cl = lines[j]
            cstripped = cl.strip()
            if not cstripped:
                j += 1
                continue
            cind = len(cl) - len(cl.lstrip(" "))
            if cind == 0:
                break
            cno = j + 1
            if cstripped.startswith("- "):
                if child is None:
                    child = []
                elif not isinstance(child, list):
                    raise YamlError(f"行 {cno}: 混合 list/dict 块")
                item_body = cstripped[2:]
                if re.match(r"^[A-Za-z][A-Za-z0-9]*:", item_body):
                    km = re.match(r"^([A-Za-z][A-Za-z0-9]*):\s*(.*)$", item_body)
                    assert km is not None
                    if not km.group(2):
                        raise YamlError(f"行 {cno}: 列表项键必须有行内值")
                    list_item = {km.group(1): _parse_scalar(km.group(2), cno)}
                    child.append(list_item)
                else:
                    if list_item is not None:
                        raise YamlError(f"行 {cno}: dict 列表与字符串列表混用")
                    child.append(_parse_scalar(item_body, cno))
            else:
                km = re.match(r"^([A-Za-z][A-Za-z0-9]*):\s*(.*)$", cstripped)
                if not km:
                    raise YamlError(f"行 {cno}: 无法解析的缩进行: {cstripped[:50]!r}")
                if isinstance(child, list):
                    if list_item is None:
                        raise YamlError(f"行 {cno}: 缩进键缺少 `- ` 列表引导")
                    if not km.group(2):
                        raise YamlError(f"行 {cno}: 列表项键必须有行内值")
                    list_item[km.group(1)] = _parse_scalar(km.group(2), cno)
                else:
                    if child is None:
                        child = {}
                    if not km.group(2):
                        raise YamlError(f"行 {cno}: 嵌套 dict 的键必须有行内值(两层以上不支持)")
                    child[km.group(1)] = _parse_scalar(km.group(2), cno)
            j += 1
        if child is None:
            raise YamlError(f"行 {line_no}: 块值 {key}: 为空(直接写行内值或删除该键)")
        data[key] = child
        i = j
    body = "\n".join(lines[end + 1:])
    return data, body


# ---------- 各项检查 ----------


def check_file(path: Path, content_dir: Path, terms: dict, routes: set[str],
               slugs_seen: dict, failures: list[str]) -> None:
    text = path.read_text(encoding="utf-8")

    def line_of(needle: str) -> int | None:
        probe = needle if len(needle) <= 24 else needle[:24]
        for idx, ln in enumerate(text.splitlines(), start=1):
            if probe in ln:
                return idx
        return None

    try:
        fm, body = parse_frontmatter(text)
    except YamlError as e:
        failures.append(f"{path.relative_to(content_dir)}: frontmatter 解析失败: {e}")
        return

    title = fm.get("title")
    description = fm.get("description")
    slug = fm.get("slug")
    lang = fm.get("lang")
    in_short = fm.get("inShort")
    faq = fm.get("faq")
    reviewed = fm.get("reviewedBy")
    published = fm.get("published", False)
    rel = path.relative_to(content_dir)

    # 1. 必填字段
    for required in ("title", "description", "slug", "lang", "inShort", "updated", "faq"):
        if required not in fm:
            failures.append(f"{rel}: 缺必填 frontmatter 字段 {required}")

    # 2. 长度与取值规则
    if isinstance(title, str) and len(title) > 60:
        failures.append(f"{rel}: title 超 60 字符({len(title)})")
    if isinstance(description, str) and not (140 <= len(description) <= 160):
        failures.append(f"{rel}: description 长度 {len(description)},要求 140–160")
    if isinstance(in_short, str):
        if CJK_RE.search(in_short):
            if len(in_short) > 120:
                failures.append(f"{rel}: inShort 中文超 120 字({len(in_short)})")
        elif len(in_short.split()) > 60:
            failures.append(f"{rel}: inShort 英文超 60 词({len(in_short.split())})")
    if isinstance(faq, list) and not (2 <= len(faq) <= 4):
        failures.append(f"{rel}: faq 必须 2–4 条(实际 {len(faq)})")
    if published and not (isinstance(reviewed, dict) and reviewed.get("date") and reviewed.get("reviewer")):
        failures.append(f"{rel}: published: true 但 reviewedBy 缺失/不完整(人工过目是发布前置)")

    # 3. 目录/文件名一致性 + slug 唯一
    parts = rel.parts  # {collection}/{lang}/{file}
    if len(parts) != 3 or parts[0] not in COLLECTIONS:
        failures.append(f"{rel}: 路径必须是 {{collection}}/{{lang}}/{{slug}}.md 形态(collection ∈ {', '.join(COLLECTIONS)})")
    else:
        collection, dir_lang, filename = parts
        if lang != dir_lang:
            failures.append(f"{rel}: frontmatter lang={lang!r} 与目录段 {dir_lang!r} 不一致")
        if isinstance(slug, str) and slug != filename[:-3]:
            failures.append(f"{rel}: slug={slug!r} 与文件名 {filename[:-3]!r} 不一致")
        key = (collection, dir_lang, slug)
        if key in slugs_seen:
            failures.append(f"{rel}: slug 重复(同 {collection}/{dir_lang} 已有 {slugs_seen[key]})")
        slugs_seen[key] = rel

    # 4. 术语键取值必须在 terms.json 对应组内(非字符串取值同样 FAIL,不靠异常兜底)
    field_groups = {"stem": "heavenlyStems", "god": "tenGods", "star": "shensha",
                    "element": "fiveElements", "branch": "earthlyBranches"}
    for field, group in field_groups.items():
        value = fm.get(field)
        if value is not None and (not isinstance(value, str) or value not in terms["groups"].get(group, {})):
            failures.append(
                f"{rel}: {field}={value!r} 不在 terms.json 组 {group} 内(译名/键必须来自单一事实源,且为字符串)"
            )

    # 5. zodiac friends/clash 手填值必须与导出一致(字段只要出现就比对;
    #    mini-YAML 只支持块状 `- ` 列表,行内 [丑, 辰] 会解析成裸字符串,同样要拦)
    if "friends" in fm or "clash" in fm:
        branch = fm.get("branch")
        exported = terms["groups"]["branchRelations"].get(branch) if isinstance(branch, str) else None
        if exported is None:
            failures.append(f"{rel}: friends/clash 手填但 branch={branch!r} 无导出关系可比对")
        else:
            friends_val = fm.get("friends")
            if friends_val is not None and not isinstance(friends_val, list):
                failures.append(
                    f"{rel}: friends 手填值解析成 {type(friends_val).__name__}"
                    f"(应为块状 `- ` 字符串列表),无法比对导出 {exported['friends']!r}"
                )
            elif friends_val is not None and friends_val != exported["friends"]:
                failures.append(f"{rel}: friends 手填 {friends_val!r} ≠ 导出 {exported['friends']!r}(关系字段由构建期导出,不手填)")
            clash_val = fm.get("clash")
            if clash_val is not None and not isinstance(clash_val, str):
                failures.append(
                    f"{rel}: clash 手填值解析成 {type(clash_val).__name__}(应为字符串),无法比对导出"
                )
            elif clash_val is not None and clash_val != exported["clash"]:
                failures.append(f"{rel}: clash 手填 {clash_val!r} ≠ 导出 {exported['clash']!r}(关系字段由构建期导出,不手填)")

    # 6. 禁词(backend scan + 额外英文 + 格局),命中报 文件:行
    #    行号按「命中原文」定位;词类标签随行展示(标签不是原文,直接拿它回查会丢行号)
    scan_targets = [x for x in (title, description, in_short, body) if isinstance(x, str)]
    if isinstance(faq, list):
        scan_targets += [f"{item.get('q', '')} {item.get('a', '')}" for item in faq if isinstance(item, dict)]
    word_hits: list[tuple[str, str]] = []  # (命中原文——用于行定位, 词类标签)
    for target in scan_targets:
        word_hits.extend((w, w) for w in backend_scan(target))
    for pattern, label in EXTRA_EN_BANNED:
        for target in scan_targets:
            m2 = re.search(pattern, target, re.IGNORECASE)
            if m2:
                word_hits.append((m2.group(0), label))
    for target in scan_targets:
        m2 = _STRUCTURE_BANNED.search(target)
        if m2:
            word_hits.append((m2.group(0), "…+structure(格局硬分类)"))
        m3 = GE_ZH_BANNED.search(target)
        if m3:
            word_hits.append((m3.group(0), "中文「……格」(格局硬分类)"))
    seen: set[tuple[str, str]] = set()
    for locate, label in word_hits:
        if (locate, label) in seen:  # 去重保序
            continue
        seen.add((locate, label))
        failures.append(f"{rel}:{line_of(locate)}: 禁词命中 {label}(原文 {locate!r})")

    # 7. 内链 ≥ 8 且全部可解析(图片 ![alt](/x) 不算内链也不按路由校验)
    links = re.findall(r"(?<!\!)\[[^\]]*\]\((/[^)]+)\)", body)
    internal = [l for l in links if not l.startswith(("http://", "https://", "mailto:", "#"))]
    if len(internal) < 8:
        failures.append(f"{rel}: 站内链接 {len(internal)} 条,要求 ≥ 8")
    for link in internal:
        clean = link.split("#")[0].rstrip("/") or "/"
        if clean not in routes:
            failures.append(f"{rel}:{line_of(link)}: 死链 {link}(路由不存在)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default=str(CONTENT), help="内容目录(默认 site/src/content)")
    args = parser.parse_args()

    try:
        terms = json.loads(TERMS_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"脚本自身错误: terms.json 读取失败 {e}(先跑 python3 tools/export_site_terms.py)", file=sys.stderr)
        return 2

    content_dir = Path(args.dir)
    if not content_dir.exists():
        print(f"脚本自身错误: 内容目录不存在 {content_dir}", file=sys.stderr)
        return 2

    files = sorted(p for p in content_dir.rglob("*.md") if not p.name.startswith("."))
    routes = set(KNOWN_STATIC_ROUTES)
    routes.update({
        f"/{parts[1]}/{parts[0]}/{parts[2][:-3]}"
        for p in files
        if len(parts := p.relative_to(content_dir).parts) == 3
    })

    failures: list[str] = []
    slugs_seen: dict = {}
    for path in files:
        check_file(path, content_dir, terms, routes, slugs_seen, failures)

    print("=" * 64)
    print(f"内容校验:{len(files)} 个文件({content_dir})")
    print("=" * 64)
    if failures:
        print(f"结果: FAIL({len(failures)} 项)")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    if not files:
        print("结果: PASS(空目录 —— S03 起才有真实内容页)")
        return 0
    print(f"结果: PASS({len(files)} 个文件全过:禁词/长度/frontmatter/内链/术语取值)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001  顶层兜底:脚本错误(exit 2)与内容 FAIL(exit 1)分开
        print(f"脚本自身错误(exit 2): {e}", file=sys.stderr)
        sys.exit(2)
