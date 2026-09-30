#!/usr/bin/env python3
"""SKU→module 映射双端一致性校验(2026-09-30,防漏单 review 唯一实质缺口)。

背景:Apple product_id → entitlement module 的映射两边各写了一份:
  backend  app/models/entitlement.py      PRODUCT_MODULE_MAP(redeem 3b 步权威反查)
  iOS      Services/PurchaseManager.swift  module(forProductID:)(restore 过滤 +
           handleRedeemContinuation 记录可信性 guard;常量在 EntitlementDTOs.swift)

为什么必须机器拦截——同一 SKU 双端 module **值**不同的杀链:
  客户端 guard(Self.module(forProductID:) == pending/ambient module)放行
  → 后端 PRODUCT_MODULE_MAP 反查不符 → 403 ENTITLEMENT_ERROR(api/entitlement.py 3b)
  → 客户端把 403 当终态 finish() → 消耗型交易 finish 不可逆,**已付款交易被销毁**。
加新 SKU 只加一边不致命(后端未知 SKU → 502 非终态 / iOS 返 nil 跳过),但同样算漂移。

比对规则(全部静态解析,**纯 stdlib 不 import backend**——无 venv 也能跑):
  ① 核心:backend PRODUCT_MODULE_MAP ↔ iOS module(forProductID:) switch
     (常量解析后)的 SKU 键集合 + 每键 module 值双相等
  ② backend 契约闭包:ProductId Literal == map 键集合;
     EntitlementModule Literal == map 值集合
  ③ iOS 闭包:AppleProductID 常量 == switch case == restorePurchases 扫描的
     productIds 集合;EntitlementModule 常量 == switch 返回值集合;case 无重复
  ④ PaywallModule 配对(Features/Paywall/PaywallViewModel.swift):productId /
     entitlementModule 两个平行 switch 按 case 合成的 (SKU, module) 对,
     每对应与 backend map 相等——它直接喂 purchase(productId:module:),
     漂移走同一条 403→finish 杀链

范围外(显式记录,不算缺口):PaywallModule 的 title/paidChapters 等纯 UI 字段。

用法:
    python3 tools/check_sku_sync.py          # 在 repo 根执行
退出码:0 = 全部一致;1 = 有 FAIL;2 = 脚本自身错误(文件缺失/标记找不到)。
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND_MODELS = ROOT / "backend/app/models/entitlement.py"
PURCHASE_MANAGER = ROOT / "ios/QiCompass/QiCompass/Services/PurchaseManager.swift"
ENTITLEMENT_DTOS = ROOT / "ios/QiCompass/QiCompass/Networking/DTOs/EntitlementDTOs.swift"
PAYWALL_VM = ROOT / "ios/QiCompass/QiCompass/Features/Paywall/PaywallViewModel.swift"

KILL_CHAIN = (
    "同一 SKU 双端 module 值不同 → 客户端 guard 放行 → 后端 403 "
    "ENTITLEMENT_ERROR → 客户端终态 finish() 销毁已付款消耗型交易(不可逆资损)"
)


# ---------- backend 侧:ast 解析 ----------

def _literal_strs(node: ast.expr) -> list[str]:
    """Literal["a", "b"] subscript 里的字符串常量列表。"""
    if isinstance(node, ast.Subscript):
        return _literal_strs(node.slice)
    if isinstance(node, ast.Tuple):
        return [e.value for e in node.elts
                if isinstance(e, ast.Constant) and isinstance(e.value, str)]
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [node.value]
    return []


def backend_tables() -> tuple[dict[str, str], set[str], set[str]]:
    tree = ast.parse(BACKEND_MODELS.read_text())
    sku_map: dict[str, str] | None = None
    product_ids: set[str] | None = None
    modules: set[str] | None = None
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
            value = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names, value = [node.target.id], node.value
        else:
            continue
        if value is None:
            continue
        if "PRODUCT_MODULE_MAP" in names:
            sku_map = ast.literal_eval(value)
        elif "ProductId" in names:
            product_ids = set(_literal_strs(value))
        elif "EntitlementModule" in names:
            modules = set(_literal_strs(value))
    missing = [n for n, v in (("PRODUCT_MODULE_MAP", sku_map),
                              ("ProductId", product_ids),
                              ("EntitlementModule", modules)) if v is None]
    if missing:
        raise ValueError(
            f"{BACKEND_MODELS.relative_to(ROOT)} 缺定义: {missing}(书写格式变了?)")
    return sku_map, product_ids, modules


# ---------- iOS 侧:Swift 静态提取 ----------

def _swift_enum_consts(text: str, enum_name: str) -> dict[str, str]:
    """`enum <name> { static let k = "v" }` 的 常量名 → 字符串值 表。"""
    i = text.index(f"enum {enum_name}")
    j = text.index("\n}", i)
    consts = dict(re.findall(r'static let (\w+)\s*=\s*"([^"]+)"', text[i:j]))
    if not consts:
        raise ValueError(f"enum {enum_name} 常量提取为空(书写格式变了?)")
    return consts


def _swift_block(text: str, start_marker: str) -> str:
    """从 marker 起,取到下一个缩进 4 的闭括号(成员函数体)。"""
    i = text.index(start_marker)
    return text[i:text.index("\n    }", i)]


_CASE_PM = re.compile(
    r"case\s+AppleProductID\.(\w+)\s*:\s*return\s+EntitlementModule\.(\w+)")


def ios_tables() -> dict[str, object]:
    dtos = ENTITLEMENT_DTOS.read_text()
    sku_consts = _swift_enum_consts(dtos, "AppleProductID")
    module_consts = _swift_enum_consts(dtos, "EntitlementModule")

    pm = PURCHASE_MANAGER.read_text()
    switch_body = _swift_block(pm, "func module(forProductID")
    cases = _CASE_PM.findall(switch_body)

    restore_body = pm[pm.index("let productIds: Set<String> = ["):
                       pm.index("]", pm.index("let productIds: Set<String> = ["))]
    restore_consts = set(re.findall(r"AppleProductID\.(\w+)", restore_body))
    return {
        "sku_consts": sku_consts,
        "module_consts": module_consts,
        "cases": cases,
        "restore_consts": restore_consts,
    }


def paywall_pairs() -> dict[str, tuple[str, str]]:
    """PaywallModule 每个 case 的 (AppleProductID 常量, EntitlementModule 常量)。"""
    text = PAYWALL_VM.read_text()
    product_arm = dict(re.findall(
        r"case\s+\.(\w+)\s*:\s*return\s+AppleProductID\.(\w+)",
        _swift_block(text, "var productId: String {")))
    module_arm = dict(re.findall(
        r"case\s+\.(\w+)\s*:\s*return\s+EntitlementModule\.(\w+)",
        _swift_block(text, "var entitlementModule: String {")))
    if set(product_arm) != set(module_arm):
        raise ValueError(
            f"PaywallModule 两个 switch case 不对齐: "
            f"仅 productId={sorted(set(product_arm) - set(module_arm))} "
            f"仅 entitlementModule={sorted(set(module_arm) - set(product_arm))}")
    return {case: (product_arm[case], module_arm[case])
            for case in product_arm}


# ---------- 主流程 ----------

def main() -> int:
    failures: list[str] = []
    b_map, b_products, b_modules = backend_tables()
    ios = ios_tables()
    sku_consts: dict[str, str] = ios["sku_consts"]
    module_consts: dict[str, str] = ios["module_consts"]
    cases: list[tuple[str, str]] = ios["cases"]
    restore_consts: set[str] = ios["restore_consts"]

    print("=" * 64)
    print("① backend PRODUCT_MODULE_MAP ↔ iOS module(forProductID:)")
    print("=" * 64)
    unknown = ({c[0] for c in cases} - set(sku_consts)) | (
        {c[1] for c in cases} - set(module_consts))
    if unknown:
        raise ValueError(f"PurchaseManager switch 引用了未定义常量: {sorted(unknown)}")
    if len(cases) != len(set(c[0] for c in cases)):
        failures.append("module(forProductID:) switch 存在重复 case(同 SKU 多分支)")
        print("  FAIL switch 重复 case")
    ios_map = {sku_consts[c[0]]: module_consts[c[1]] for c in cases}

    b_keys, i_keys = set(b_map), set(ios_map)
    if b_keys != i_keys:
        failures.append(
            f"SKU 键集合漂移: 仅backend={sorted(b_keys - i_keys)} "
            f"仅iOS={sorted(i_keys - b_keys)}")
        print(f"  FAIL 键集合漂移(仅backend={sorted(b_keys - i_keys)} "
              f"仅iOS={sorted(i_keys - b_keys)})")
    value_drift = {k: (b_map[k], ios_map[k])
                   for k in b_keys & i_keys if b_map[k] != ios_map[k]}
    if value_drift:
        detail = "; ".join(
            f"{k}: backend={bv!r} iOS={iv!r}"
            for k, (bv, iv) in sorted(value_drift.items()))
        failures.append(f"module 值漂移(资损链: {KILL_CHAIN}): {detail}")
        print(f"  FAIL module 值漂移 {len(value_drift)} 条 —— {KILL_CHAIN}")
    if not value_drift and b_keys == i_keys:
        for sku in sorted(b_map):
            print(f"  OK   {sku:<42} → {b_map[sku]}")

    print("=" * 64)
    print("② backend 契约闭包(ProductId / EntitlementModule Literal)")
    print("=" * 64)
    if b_products != b_keys:
        failures.append(
            f"ProductId Literal ≠ map 键: 仅Literal={sorted(b_products - b_keys)} "
            f"仅map={sorted(b_keys - b_products)}")
        print("  FAIL ProductId Literal ≠ PRODUCT_MODULE_MAP 键集合")
    else:
        print(f"  OK   ProductId Literal == map 键集合({len(b_products)} 个 SKU)")
    if not b_modules <= set(b_map.values()):
        failures.append(
            f"EntitlementModule Literal 有未映射值: "
            f"{sorted(b_modules - set(b_map.values()))}")
        print("  FAIL EntitlementModule Literal ⊄ map 值集合")
    elif b_modules != set(b_map.values()):
        failures.append(
            f"map 值不在 EntitlementModule Literal 内: "
            f"{sorted(set(b_map.values()) - b_modules)}")
        print("  FAIL map 值 ⊄ EntitlementModule Literal")
    else:
        print(f"  OK   EntitlementModule Literal == map 值集合({sorted(b_modules)})")

    print("=" * 64)
    print("③ iOS 闭包(AppleProductID / EntitlementModule 常量 ↔ 消费点)")
    print("=" * 64)
    case_consts = {c[0] for c in cases}
    if set(sku_consts) != case_consts:
        failures.append(
            f"AppleProductID 常量 ≠ switch case: 仅常量={sorted(set(sku_consts) - case_consts)} "
            f"仅case={sorted(case_consts - set(sku_consts))}")
        print("  FAIL AppleProductID 常量 ≠ module(forProductID:) case(新 SKU 漏 switch → 返 nil 被跳过)")
    else:
        print(f"  OK   AppleProductID {len(sku_consts)} 常量全进 switch")
    if restore_consts != set(sku_consts):
        failures.append(
            f"restorePurchases productIds ≠ AppleProductID 常量: "
            f"仅restore={sorted(restore_consts - set(sku_consts))} "
            f"仅常量={sorted(set(sku_consts) - restore_consts)}")
        print("  FAIL restore 扫描集合 ≠ AppleProductID 常量(新 SKU 漏扫描 → 永不恢复)")
    else:
        print("  OK   restorePurchases productIds == AppleProductID 常量")
    used_modules = {c[1] for c in cases}
    if set(module_consts) != used_modules:
        failures.append(
            f"EntitlementModule 常量 ≠ switch 返回值: 仅常量={sorted(set(module_consts) - used_modules)} "
            f"仅返回={sorted(used_modules - set(module_consts))}")
        print("  FAIL EntitlementModule 常量 ≠ switch 返回值集合")
    else:
        print(f"  OK   EntitlementModule {len(module_consts)} 常量全被 switch 返回")

    print("=" * 64)
    print("④ PaywallModule 配对(productId/entitlementModule 平行 switch)")
    print("=" * 64)
    pairs = paywall_pairs()
    pair_drift = []
    for case, (sku_c, mod_c) in sorted(pairs.items()):
        sku, mod = sku_consts[sku_c], module_consts[mod_c]
        if b_map.get(sku) != mod:
            pair_drift.append(
                f"{case}: SKU {sku!r} 配 module {mod!r},backend map 为 "
                f"{b_map.get(sku)!r}")
        else:
            print(f"  OK   .{case:<14} {sku:<42} → {mod}")
    if pair_drift:
        failures.append(
            f"PaywallModule 配对漂移(它直接喂 purchase(productId:module:),"
            f"走 403→finish 杀链: {KILL_CHAIN}): {'; '.join(pair_drift)}")

    print("=" * 64)
    if failures:
        print(f"结果: FAIL({len(failures)} 项)")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("结果: PASS")
    print("范围外(显式记录):PaywallModule 的 title/paidChapters 等纯 UI 字段"
          "不参与 SKU→module 映射比对。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FileNotFoundError, ValueError, IndexError) as e:
        print(f"脚本自身错误(文件缺失/标记找不到/书写格式变了): {e}", file=sys.stderr)
        sys.exit(2)
