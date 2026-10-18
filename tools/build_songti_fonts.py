#!/usr/bin/env python3
"""构建 QiSongti / QiSongtiTC 子集字体(思源宋体 → 全 App 中文主字体)。

背景(2026-10-18 晚拍板):S1b 打包的霞鹜文楷(教科书手写体血统,源自 Klee One)
上真机后用户不满,主字体全宋体化——展示层/正文/干支/品牌层统一思源宋体,文楷退役。
QiSongti 从「图内宋专用 799 字子集」扩为全 App 字符集子集;zh-hant 腿新增 QiSongtiTC。

字源(OFL 2.003R,Adobe 官方,本地不放仓里):
  CN: https://github.com/adobe-fonts/source-han-serif/releases/download/2.003R/14_SourceHanSerifCN.zip
      → SubsetOTF/CN/SourceHanSerifCN-Regular.otf
  TC: 繁体腿用 **TW 子集**(git release 分支无 TC 目录;TW = 台湾标准字形,
      与 TC 子集默认字形一致,Big5 全覆盖实测)——jsDelivr 直链(快):
      https://cdn.jsdelivr.net/gh/adobe-fonts/source-han-serif@release/SubsetOTF/TW/SourceHanSerifTW-Regular.otf
      备选 release 资产 10_SourceHanSerifTC.zip(138MB,含 SubsetOTF/TC/)。
OFL 保留字体名 "Source" → 子集必须改名( QiSongti / QiSongtiTC,S1b 已确立)。

字符集:
  SC = GBK 全部汉字(含人名用字,防命主名/合盘名缺字回退苹方)∪ App 全部源码/词条 CJK
       ∪ ASCII ∪ CJK 标点/全角/常用符号
  TC = Big5 全区(常用+次常用)∪ 同上扫描 ∪ 同上符号
  覆盖外字符(生僻)由 Core Text 逐字级联回退系统字体——姓名/正文罕见字可接受。

用法(仓库根):
  python3 tools/build_songti_fonts.py            # 构建并写入 Resources + 自检
  python3 tools/build_songti_fonts.py --verify   # 只校验已提交的 Resources 字体
依赖:fontTools ≥ 4.x(pip3 install fonttools;本机系统 python3 4.63 实测可用)。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parent.parent
IOS_SOURCES = REPO / "ios" / "QiCompass" / "QiCompass"
XCSTRINGS = IOS_SOURCES / "Resources" / "Localizable.xcstrings"
# 术语表与后端镜像(渲染层字符串的事实源,缺字必须 FAIL 而非 warn)
HARD_SOURCES = [
    REPO / "backend" / "app" / "engine" / "term_translations.py",
]
RESOURCES = IOS_SOURCES / "Resources"
SC_OUT = RESOURCES / "QiSongti-Regular.otf"
TC_OUT = RESOURCES / "QiSongtiTC-Regular.otf"

FAMILY_SC = "QiSongti"
FAMILY_TC = "QiSongtiTC"

# 渲染层必然用到的符号(区间外逐个补)
EXTRA_SYMBOLS = "·—…‘’“”〇〈〉《》「」『』【】〔〕〜％￥°↑↓←→♂♀♦"


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


def gbk_chars() -> set[str]:
    # lead 0x81-0xFE 全扫(含 0xFD/0xFE 两行 79 个可作人名的生僻字,齡齣龘…);
    # 只扫到 0xFC 会漏人名用字——「齡」曾仅靠 app 词条 union 侥幸兜住。
    return codec_chars("gbk", range(0x81, 0xFF), range(0x40, 0xFF))


def big5_chars() -> set[str]:
    # lead 0xA1-0xF9 全扫(0xF9 行 116 个次常用尾字,圞戇欞…;Python big5
    # 解码器实测支持);hant_subset 的 allowed 集同源,漏行 = 硬校验盲区。
    return codec_chars("big5", range(0xA1, 0xFA), range(0x40, 0xFF))


def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3000 <= cp <= 0x9FFF
        or 0xF900 <= cp <= 0xFAFF
        or 0xFF00 <= cp <= 0xFFEF
        or ch in EXTRA_SYMBOLS
    )


def scan_app_chars() -> tuple[set[str], set[str]]:
    """返回 (全部扫描 CJK 字符, 硬性要求字符)。

    硬性要求 = xcstrings 全部语言值 + term_translations.py(经 API 渲染到界面,
    缺字直接 FAIL);其余 .swift(注释居多)缺字不 FAIL——构建时随扫描并入字符集,
    verify 对其无校验(改 swift 字面量后须重跑构建而非 --verify)。
    """
    all_chars: set[str] = set()
    hard_chars: set[str] = set()

    xc = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    for entry in xc.get("strings", {}).values():
        for unit in entry.get("localizations", {}).values():
            value = unit.get("stringUnit", {}).get("value", "")
            for ch in value:
                if is_cjk(ch):
                    all_chars.add(ch)
                    hard_chars.add(ch)
            # variations 结构:{"plural": {"one": {"stringUnit": …}, …}} —
            # 须下钻到每个变体的 stringUnit,取容器层会漏全部复数/设备文案。
            for variation in unit.get("variations", {}).values():
                for variant in variation.values():
                    value = variant.get("stringUnit", {}).get("value", "")
                    for ch in value:
                        if is_cjk(ch):
                            all_chars.add(ch)
                            hard_chars.add(ch)

    for path in HARD_SOURCES:
        for ch in path.read_text(encoding="utf-8"):
            if is_cjk(ch):
                all_chars.add(ch)
                hard_chars.add(ch)

    for path in sorted(IOS_SOURCES.rglob("*.swift")):
        for ch in path.read_text(encoding="utf-8"):
            if is_cjk(ch):
                all_chars.add(ch)

    return all_chars, hard_chars


def base_charset(extra: set[str]) -> set[int]:
    chars = set(EXTRA_SYMBOLS) | extra
    chars |= {chr(c) for c in range(0x20, 0x7F)}  # ASCII 可打印(宋体自带衬线拉丁)
    return {ord(c) for c in chars}


def build_subset(source: Path, out: Path, family: str, unicodes: set[int]) -> None:
    src = TTFont(str(source))

    opts = subset.Options()
    opts.name_IDs = list(range(0, 32))  # 保留全部 name 记录(OFL 署名/许可文本)
    opts.name_languages = ["*"]
    opts.glyph_names = False
    opts.recalc_bounds = True
    opts.layout_features = ["*"]  # 保留 vert/vrt2 竖排特性
    font = subset.load_font(str(source), opts)
    subsetter = subset.Subsetter(options=opts)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)

    # name 表整表复用源字体后改族名(OFL RFN "Source" 合规 + 对齐 S1b 既有口径)。
    # 1/2/3/4/6 对**全部语言记录**覆写——源字体中文记录(思源宋体 CN/TW)残留
    # 会让 nameID 1 出现多值,探测与匹配行为不确定。
    font["name"] = src["name"]
    ps = f"{family}-Regular"
    override = {1: family, 2: "Regular", 3: f"{ps};QiCompass", 4: f"{family} Regular", 6: ps}
    for record in list(font["name"].names):
        if record.nameID in override:
            record.string = override[record.nameID]
    # 16/17(typographic family/subfamily)若存在则删除,避免旧族名残留
    font["name"].names = [
        r for r in font["name"].names if r.nameID not in (16, 17)
    ]

    font.save(str(out))


def verify(out: Path, family: str, hard: set[str], label: str) -> list[str]:
    problems: list[str] = []
    font = TTFont(str(out))
    cmap = font.getBestCmap()
    name_family = {r.toUnicode() for r in font["name"].names if r.nameID == 1}
    if name_family != {family}:
        problems.append(f"{label}: nameID 1 = {name_family},应为 {{'{family}'}}")
    missing = sorted(ch for ch in hard if ord(ch) not in cmap)
    if missing:
        problems.append(f"{label}: 硬性字符缺失 {len(missing)} 个: {''.join(missing[:50])}")
    size_mb = out.stat().st_size / 1e6
    print(f"{label}: {font['maxp'].numGlyphs} glyphs, {size_mb:.2f} MB, "
          f"覆盖硬性字符 {len(hard) - len(missing)}/{len(hard)}")
    return problems


def hant_subset(chars: set[str]) -> set[str]:
    """TC 腿的硬性要求 = 硬字符 ∩ (Big5 ∪ 符号/ASCII)。

    zh(简体)词条由 SC 腿渲染;TW 字体无简体字形是**正确**行为,不该 FAIL。
    zh-Hant 文案 = 台湾标准传统字,落在 Big5 内;Big5 外的硬字符多为简体,
    若确有繁体罕字落在 Big5 外且缺失,verify 的 missing 清单会暴露出来人工判断。
    """
    allowed = big5_chars() | set(EXTRA_SYMBOLS) | {chr(c) for c in range(0x20, 0x7F)}
    return {ch for ch in chars if ch in allowed}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cn-source", default="/private/tmp/s1b-fonts/shs-cn/SubsetOTF/CN/SourceHanSerifCN-Regular.otf")
    parser.add_argument("--tc-source", default="/private/tmp/s1b-fonts/SourceHanSerifTW-Regular.otf")
    parser.add_argument("--verify", action="store_true", help="只校验 Resources 已有产物")
    args = parser.parse_args()

    app_chars, hard_chars = scan_app_chars()
    print(f"App 扫描:CJK {len(app_chars)} 字(硬性 {len(hard_chars)})")

    if not args.verify:
        sc_set = base_charset(app_chars) | {ord(c) for c in gbk_chars()}
        tc_set = base_charset(app_chars) | {ord(c) for c in big5_chars()}
        print(f"SC charset: {len(sc_set)} | TC charset: {len(tc_set)}")
        cn_src, tc_src = Path(args.cn_source), Path(args.tc_source)
        for p, label in [(cn_src, "CN 源"), (tc_src, "TC 源")]:
            if not p.exists():
                print(f"FAIL: {label}字体不存在:{p}(下载见文件头 docstring)", file=sys.stderr)
                return 1
        build_subset(cn_src, SC_OUT, FAMILY_SC, sc_set)
        build_subset(tc_src, TC_OUT, FAMILY_TC, tc_set)
        print(f"已写入 {SC_OUT.name} / {TC_OUT.name}")

    problems = verify(SC_OUT, FAMILY_SC, hard_chars, "QiSongti(SC)")
    problems += verify(TC_OUT, FAMILY_TC, hant_subset(hard_chars), "QiSongtiTC(TC)")
    # GB2312 一级二级核心覆盖兜底断言(GBK ⊇ GB2312,防源字体异常)
    sc_cmap = TTFont(str(SC_OUT)).getBestCmap()
    gb2312 = codec_chars("gb2312", range(0xB0, 0xF8), range(0xA1, 0xFF))
    missing = sorted(ch for ch in gb2312 if ord(ch) not in sc_cmap)
    if missing:
        problems.append(f"GB2312 缺失 {len(missing)} 字:{''.join(missing[:50])}")
    # Big5 常用字区(A440-C67E)兜底断言(对称 GB2312,防源字体异常)
    tc_cmap = TTFont(str(TC_OUT)).getBestCmap()
    big5_common = codec_chars("big5", range(0xA4, 0xC7), range(0x40, 0xFF))
    missing = sorted(ch for ch in big5_common if ord(ch) not in tc_cmap)
    if missing:
        problems.append(f"Big5 常用字缺失 {len(missing)} 字:{''.join(missing[:50])}")

    if problems:
        print("FAIL:", file=sys.stderr)
        for p in problems:
            print(" -", p, file=sys.stderr)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
