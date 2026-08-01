# 0010 — AI provider 单选(anthropic | openai),不自动 fallback

Status: accepted (2026-07-09)

后端启动时按 `AI_PROVIDER=anthropic|openai` 单选一个 `AIClient`。Anthropic 走 Messages API(默认 `claude-sonnet-4-6`),OpenAI 走官方 Responses API(默认 `gpt-5.5`),统一 15 秒超时 + 1024 输出 token 上限。`AI_PROVIDER` 非法时启动失败。所选 provider 缺 key 时非 AI 路由仍可用,`/api/interpret` 返回 503。上游超时 / 网络错误 / 拒绝 / 空响应 / 非成功状态都显式传播,**禁止调用另一供应商兜底**。

**Why**:
1. prompt 模板对每个 provider 单独调优,自动 fallback 会让用户拿到不同风格的命书,破坏一致性体验
2. provider 切换是部署级事件,不应该由运行时按"可用性"自动决定
3. 跨 provider 缓存污染 — Anthropic 缓存的结果不能冒充 OpenAI 缓存(见 ADR 0009 缓存键含 provider/model)

**Surprising without context**: 一般 AI gateway 默认会做 fallback(主 provider 挂了切备用),这里故意不做。`AI_PROVIDER` 非法直接启动失败而不是默认 Anthropic,也是同样的"显式失败优于隐式默认"哲学。

**Real trade-off**:
- ✅ 单选 + 显式错误 — 一致性 + 可预测 + 缓存干净
- ❌ 多 provider + 自动 fallback — 复杂度高 + 风格不一致 + 缓存污染
- ❌ LiteLLM / portkey 等统一层 — 引入新依赖(违反 CLAUDE.md "不擅自加依赖")

**Consequences**: provider 切换是部署级操作(改环境变量 + 重启),不是运行时决策。用户感知到的 provider 切换 = 旧缓存全部 miss + 新身份重新生成。
