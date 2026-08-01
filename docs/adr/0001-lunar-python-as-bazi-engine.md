# 0001 — lunar_python 作为后端权威排盘库,客户端不做历法

Status: accepted (2026-07-09)

所有八字排盘计算走后端 FastAPI + `lunar_python`(6tail/lunar-python,纯 Python 无依赖),客户端只做渲染,不做任何历法计算。API key 不进客户端,provider 只能由部署环境选择。

**Why**: 八字计算必须 100% 确定性(同一输入永远同一输出)。客户端计算会引入设备时钟 / 时区 / 历法库版本差异,破坏这一约束。后端单一权威库 + `calc_rule_snapshot` 规则快照随盘存档,才能保证可复现。

**Considered Options**:
- ✅ 后端 `lunar_python` — spike 验证支持四柱/十神/纳音/藏干/十二长生/旬空/大运/流年流月/黄历/节气全字段
- ❌ 客户端 Swift 历法库 — iOS 没有可靠的八字库,且会破坏确定性约束
- ❌ 其他 Python 库(sxtwl / bazi) — 字段不全或维护停滞

**Consequences**: lunar_python 是同步 CPU-bound 库,FastAPI async event loop 必须用 `anyio.to_thread.run_sync()` 或 `starlette.concurrency.run_in_threadpool` 包,否则阻塞。库不给喜忌 + 不给 20 个八字神煞,这两块必须自写(见 ADR 0004 / 0005)。
