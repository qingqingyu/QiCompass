#!/usr/bin/env python3
"""prompt 一致性校验:iOS ↔ promo-site ↔ backend(方案 A,2026-08-13 拍板)。

单一事实源:backend `REQUIRED_FIELDS` / `PROMPT_VERSIONS`(iOS 与 promo-site 都是消费者)。
背景:三模块的 prompt 文本全在 backend 渲染(iOS 无 prompt 文本),天然一致;但
**上下文字段映射**有三份实现(backend 校验清单 / Swift builder / promo Python builder),
v1 module 清单也是三处各写一遍——本脚本拦这两类漂移。

比对规则:
  1. 三模块 context 字段:REQUIRED_FIELDS[module] ⊆ builder keys(缺失 = FAIL)
     builder 多出的字段只 WARN(允许展示用扩展字段),不算失败
  2. v1 module ID 集合:backend PROMPT_VERSIONS(m*) = iOS ModuleDefinitions = promo v1_chain(不相等 = FAIL)

用法:
    python3 tools/check_prompt_sync.py          # 在 repo 根执行
退出码:0 = 全部一致;1 = 有 FAIL;2 = 脚本自身错误(文件缺失等)。

注意:promo-site 在 tmp/(gitignore),CI 里不存在 → 打 SKIP 不失败;本地开发应存在。
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
PROMO = ROOT / "tmp" / "promo-site"

# ---------- backend 事实源(import;需先垫 JWT 占位,原因同 promo-site main.py) ----------

sys.path.insert(0, str(BACKEND))
os.environ.setdefault("JWT_SECRET_KEY", "prompt-sync-check-not-used")

from app.ai.prompts import PROMPT_VERSIONS, REQUIRED_FIELDS  # noqa: E402

# ---------- 提取器 ----------

# Swift dict 字面量键:"key": AnyCodableJSON(  —— anchor 到 AnyCodableJSON 避免误抓普通字符串
_SWIFT_KEY = re.compile(r'"([a-z0-9_]+)":\s*AnyCodableJSON\(')


def _slice(text: str, start: str, end: str | None) -> str:
    i = text.index(start)
    j = text.index(end) if end else len(text)
    return text[i:j]


def swift_keys(path: Path, start: str, end: str | None = None) -> set[str]:
    return set(_SWIFT_KEY.findall(_slice(path.read_text(), start, end)))


def promo_runtime_keys() -> dict[str, set[str]] | None:
    """运行时调用 promo 的三个 context builder,取真实输出键集。

    不用静态正则:promo builder 用 helper 函数/spike 透传/f-string 拼键
    (如 f"{k}_a"),静态提取会大面积假阳性。BaziEngine 确定性,同盘同输出,
    无 AI 调用。对齐 promo main.py 的调用方式(含 _chart_dict_to_payload 逻辑)。
    """
    if not (PROMO / "context_builder.py").exists():
        return None
    sys.path.insert(0, str(PROMO))

    from datetime import date, datetime, timedelta, timezone

    from app.engine.bazi_engine import BaziEngine
    from app.engine.compatibility import compute_compatibility
    from app.engine.daily_fortune import compute_daily_fortune
    from app.models.compatibility import CompatibilityRequest
    from app.models.daily_fortune import ChartPayload
    from context_builder import build_bazi_context, build_compat_context, build_daily_context

    def to_payload(chart: dict) -> ChartPayload:
        p = chart["pillars"]
        return ChartPayload(
            day_master=p["day"]["gan"],
            day_master_element=p["day"]["gan_element"],
            day_master_strength=chart["day_master_strength"],
            favorable_elements=chart["favorable_elements"],
            unfavorable_elements=chart["unfavorable_elements"],
            four_pillars={
                pos: {"gan": p[pos]["gan"], "zhi": p[pos]["zhi"]}
                for pos in ("year", "month", "day", "hour")
            },
            luck_pillars=chart["luck_pillars"],
            calc_rule_snapshot=chart.get("calc_rule_snapshot"),
        )

    engine = BaziEngine()
    tz = timezone(timedelta(hours=8))
    birth_a = datetime(1990, 1, 15, 11, 0, tzinfo=tz)
    birth_b = datetime(1992, 6, 20, 15, 0, tzinfo=tz)
    chart_a = engine.calculate(
        birth=birth_a, gender="male", longitude=116.41, zi_hour_rule="zi_next_day",
    )
    chart_b = engine.calculate(
        birth=birth_b, gender="female", longitude=121.47, zi_hour_rule="zi_next_day",
    )

    bazi_keys = set(build_bazi_context(chart_a, birth_a, "male", 116.41, city="北京"))

    compat_resp = compute_compatibility(req=CompatibilityRequest(
        person_a_hash=chart_a["content_hash"],
        person_b_hash=chart_b["content_hash"],
        chart_payload_a=to_payload(chart_a),
        chart_payload_b=to_payload(chart_b),
        context="general",
    ))
    compat_keys = set(build_compat_context(
        chart_a, chart_b, compat_resp,
        birth_a, birth_b, "male", "female", 116.41, 121.47,
        context_label_key="general", city_a="北京", city_b="上海",
    ))

    target = date(2026, 8, 13)
    daily_resp = compute_daily_fortune(
        chart_hash=chart_a["content_hash"],
        target_date=target,
        chart_payload=to_payload(chart_a),
    )
    daily_keys = set(build_daily_context(chart_a, daily_resp, target))

    return {
        "bazi_deep": bazi_keys,
        "compatibility": compat_keys,
        "daily_fortune": daily_keys,
    }


def ios_v1_modules() -> set[str]:
    text = (ROOT / "ios/QiCompass/QiCompass/Models/ModuleDefinitions.swift").read_text()
    return set(re.findall(r'=\s*"(m\d_[a-z_]+)"', text))


def promo_v1_modules() -> set[str] | None:
    f = PROMO / "v1_chain.py"
    if not f.exists():
        return None
    return set(re.findall(r'"(m\d_[a-z_]+)":\s*\{', f.read_text()))


# ---------- 主流程 ----------

def main() -> int:
    failures: list[str] = []
    warnings: list[str] = []

    pb = ROOT / "ios/QiCompass/QiCompass/Services/PromptContextBuilder.swift"
    pc = ROOT / "ios/QiCompass/QiCompass/Services/PromptContextBuilder+Compatibility.swift"

    ios_builders = {
        # module 组(取 paid 代表;free/paid 同一份字段清单) → Swift 提取
        "bazi_deep": swift_keys(pb, "static func build(", "static func buildV1ChartJSON"),
        "compatibility": swift_keys(pc, "static func buildCompatibility"),
        "daily_fortune": swift_keys(pb, "static func buildDailyFortune("),
    }

    promo_builders: dict[str, set[str] | None] = {k: None for k in ios_builders}
    try:
        runtime = promo_runtime_keys()
    except Exception as e:  # noqa: BLE001 —— promo 侧任何失败显式降级为 FAIL,不能静默
        failures.append(f"promo builder 运行时调用失败({type(e).__name__}: {e})——可能是 promo 在 CI 缺失以外的原因,须排查")
        runtime = None
    if runtime is not None:
        promo_builders = runtime  # type: ignore[assignment]
    elif not failures or all("promo builder" not in f for f in failures):
        warnings.append("promo-site 不存在(tmp/ 被 gitignore?),promo 侧比对 SKIP(CI 场景正常,本地应有)")

    print("=" * 64)
    print("① 三模块 context 字段(backend REQUIRED ⊆ builder keys)")
    print("=" * 64)
    for module, required in REQUIRED_FIELDS.items():
        if module.startswith("m") and "_" in module:
            continue  # v1 module 走下面 ②
        req = set(required)
        for side, keys in (("ios", ios_builders.get(module)), ("promo", promo_builders.get(module))):
            if keys is None:
                continue
            missing = req - keys
            extra = keys - req
            label = f"  {module:<16} {side:<5}"
            if missing:
                failures.append(f"{module}({side}) 缺字段: {sorted(missing)}")
                print(f"{label} FAIL 缺 {sorted(missing)}")
            else:
                note = f" WARN 多出 {sorted(extra)}" if extra else ""
                if note:
                    warnings.append(f"{module}({side}) 多出 {sorted(extra)}")
                print(f"{label} OK   {len(req)} 字段全命中{note}")

    print("=" * 64)
    print("② v1 module ID 集合(三边必须相等)")
    print("=" * 64)
    backend_v1 = {k for k in PROMPT_VERSIONS if re.match(r"^m\d_", k)}
    ios_v1 = ios_v1_modules()
    promo_v1 = promo_v1_modules()

    print(f"  backend ({len(backend_v1)}): {sorted(backend_v1)}")
    print(f"  ios     ({len(ios_v1)}): {sorted(ios_v1)}")
    if promo_v1 is not None:
        print(f"  promo   ({len(promo_v1)}): {sorted(promo_v1)}")

    if backend_v1 != ios_v1:
        failures.append(f"v1 module 不一致 backend↔ios: 仅backend={sorted(backend_v1 - ios_v1)} 仅ios={sorted(ios_v1 - backend_v1)}")
    if promo_v1 is not None and backend_v1 != promo_v1:
        failures.append(f"v1 module 不一致 backend↔promo: 仅backend={sorted(backend_v1 - promo_v1)} 仅promo={sorted(promo_v1 - backend_v1)}")
    if not failures or all("v1 module" not in f for f in failures):
        print("  三边一致 ✓" if promo_v1 is not None else "  backend↔ios 一致 ✓(promo SKIP)")

    print("=" * 64)
    if failures:
        print(f"结果: FAIL({len(failures)} 项)")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print(f"结果: PASS(warning {len(warnings)} 项,均为扩展字段/跳过,不算失败)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FileNotFoundError, ValueError) as e:
        print(f"脚本自身错误(文件缺失/标记找不到): {e}", file=sys.stderr)
        sys.exit(2)
