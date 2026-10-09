"""LLM 调用监控(2026-10-09 A 档闭环):

- store.LLMOutcomeStore:小时粒度调用结果计数 + 最近失败快照(SQLite)
- metered.MeteredAIClient:包装 AIClient,记录成功/失败并原样上抛;
  失败率达阈值打 ERROR 级 ALERT 标记日志
- 展示出口:/api/health/llm(api/health.py)
"""
