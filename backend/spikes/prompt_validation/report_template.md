# Prompt 验证报告模板(方案 §1.6)

> 本文件是报告骨架。跑完 spike 后,按此模板填写 `report_v{N}.md`。

---

## 元信息

- **日期**: {YYYY-MM-DD}
- **Prompt 版本**: v{N}
- **Claude 模型**: {model}
- **样本数**: 20(15 普通盘 + 2 专旺 + 3 从格)
- **Spike 轮次**: 第 {N} 轮(上限 3 轮)

---

## 1. 逐盘评分表

| Case | 类别 | 季节/特征 | 五行完整 | 十神配置 | 神煞准确 | 大运流年 | 无硬性格局 | 严格遵守喜忌 | special诚实 | 整体 | 通过 |
|------|------|-----------|---------|---------|---------|---------|-----------|------------|-------------|------|------|
| 00 | 普通 | 春·初春 | | | | | | | N/A | | |
| 01 | 普通 | 春·仲春 | | | | | | | N/A | | |
| ... | ... | ... | | | | | | | | | |
| 15 | 专旺 | 专旺水 | | | | | | | | | |
| 16 | 专旺 | 专旺火 | | | | | | | | | |
| 17 | 从格 | 从火 | | | | | | | | | |
| 18 | 从格 | 从水 | | | | | | | | | |
| 19 | 从格 | 从土 | | | | | | | | | |

---

## 2. 失败维度聚类

| 失败维度 | 出现次数 | 涉及 Case | 典型问题 |
|---------|---------|----------|---------|
| 五行完整 | | | |
| 十神配置 | | | |
| 神煞准确 | | | |
| 大运流年 | | | |
| 无硬性格局 | | | |
| 严格遵守喜忌 | | | |
| special_pattern 诚实 | | | |

---

## 3. Special Pattern 专项结果

- 专旺水(case_15): day_master_strength={strength}, favorable={favorable}, 断言={passed}
- 专旺火(case_16): day_master_strength={strength}, favorable={favorable}, 断言={passed}
- 从火(case_17): day_master_strength={strength}, favorable={favorable}, 断言={passed}
- 从水(case_18): day_master_strength={strength}, favorable={favorable}, 断言={passed}
- 从土(case_19): day_master_strength={strength}, favorable={favorable}, 断言={passed}

### LLM 输出抽样(从格诚实降级验证)

> 检查 LLM 是否明确表达"不入常格扶抑框架",不编造喜忌。

- case_15 摘录: `{llm_response_excerpt}`
- case_17 摘录: `{llm_response_excerpt}`

---

## 4. 典型好/坏输出摘录

### 好输出(整体 ≥ 4.5)

**Case {N}**({category}/{season}):

```
{llm_response_excerpt}
```

亮点: {highlight}

### 坏输出(整体 < 4.0)

**Case {N}**({category}/{season}):

```
{llm_response_excerpt}
```

问题: {issue}

---

## 5. 结论

- **平均分**: {avg_score}/5.0
- **通过率**: {passed_count}/20(≥ 4.0)
- **是否达标**: {是/否}(≥ 4.0 为达标)
- **是否需要迭代**: {是/否}

---

## 6. Prompt 调整建议(若需迭代)

| 问题 | 建议调整 | 影响 prompt 段 |
|------|---------|--------------|
| {issue} | {suggestion} | {prompt_section} |

> 调整后 bump `PROMPT_VERSIONS["bazi_deep"]` → v{N+1},重跑全部 20 盘。

---

## 7. API 调用日志汇总

| Case | module | prompt_version | model | 耗时(ms) | special_pattern | error |
|------|--------|---------------|-------|---------|----------------|-------|
| 00 | bazi_deep | v{N} | {model} | | false | |
| ... | ... | ... | ... | | | |
