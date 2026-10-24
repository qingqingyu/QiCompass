prompt_versions 一致:是

| 指标 | GLM | DeepSeek | Claude | GPT-5.5 | Gemini | Luna | 4o-mini |
|---|---|---|---|---|---|---|---|
| 模型身份(meta) | anthropic/glm-5.2 | openai/deepseek-chat | anthropic/claude-opus-5-5 | openai/openai/gpt-5.5 | openai/google/gemini-3.1-pro-preview | openai/openai/gpt-6-luna | openai/openai/gpt-4o-mini |
| verdict 分布 pass/warn/fail/error | 63/21/41/35 | 65/57/25/13 | 105/0/35/20 | 119/0/27/14 | 50/0/51/59 | 81/0/70/9 | 110/0/50/0 |
| **生产首调失败**(JSON+禁词+生成报错)/实际调用 | 20/132(15%) | 1/160(1%) | 31/160(19%) | 3/148(2%) | 55/114(48%) | 53/151(35%) | 0/160(0%) |
|   JSON 解析失败 | 8 | 0 | 1 | 1 | 0 | 4 | 0 |
|   禁词命中 | 12 | 1 | 10 | 0 | 42 | 49 | 0 |
|   生成侧报错(含上下文超长) | 0 | 0 | 20 | 2 | 13 | 0 | 0 |
| 连带失败(上游坏导致未调用) | 28 | 0 | 0 | 12 | 46 | 9 | 0 |
| 红线:喜忌矛盾 | 3 | 2 | 0 | 0 | 5 | 0 | 0 |
| 红线:编造喜忌 | 1 | 0 | 0 | 0 | 1 | 0 | 0 |
| 红线:地支五行错置 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| 红线:硬性格局 | 0 | 0 | 14 | 2 | 0 | 0 | 0 |
| 延迟 中位/P90/最大(秒) | 37.8/54.8/89.5 | 10.2/20.0/26.3 | 78.3/127.8/470.3 | 50.1/76.5/117.9 | 57.5/81.9/101.3 | 35.1/51.0/68.6 | 10.1/16.4/32.0 |

### GLM 全部失败类别

- 21 × ERROR:InvalidInputError
- 12 × 生产禁词命中
- 12 × special_pattern 隐藏降级
- 8 × JSON 解析失败
- 7 × ERROR:裁判失败
- 7 × ERROR:链路中断
- 4 × 展开层含干支
- 3 × 喜忌矛盾
- 2 × 展开层含数字
- 2 × 照抄示例
- 1 × environment_checklist 长度 1 != 期望 5
- 1 × special_pattern 编造喜忌
- 1 × structure_fingerprint 长度 49 超 40 字
- 1 × 地支五行错置

### DeepSeek 全部失败类别

- 14 × special_pattern 隐藏降级
- 13 × ERROR:裁判失败
- 7 × 照抄示例
- 3 × 展开层含干支
- 2 × 展开层含数字
- 2 × 喜忌矛盾
- 1 × 机器字段名外泄
- 1 × 生产禁词命中

### Claude 全部失败类别

- 20 × ERROR:AIProviderError
- 19 × special_pattern 隐藏降级
- 14 × 硬性格局
- 10 × 生产禁词命中
- 2 × 照抄示例
- 2 × 权重>0写缺
- 1 × JSON 解析失败
- 1 × 展开层含数字
- 1 × 缺字段

### GPT-5.5 全部失败类别

- 15 × 链式不一致
- 12 × ERROR:InvalidInputError
- 9 × special_pattern 隐藏降级
- 2 × 硬性格局
- 2 × ERROR:AIProviderError
- 1 × JSON 解析失败

### Gemini 全部失败类别

- 46 × ERROR:InvalidInputError
- 42 × 生产禁词命中
- 13 × ERROR:AIProviderError
- 9 × special_pattern 隐藏降级
- 5 × 喜忌矛盾
- 2 × v1 §4 扩展禁词命中
- 1 × structure_fingerprint 长度 43 超 40 字
- 1 × special_pattern 编造喜忌

### Luna 全部失败类别

- 49 × 生产禁词命中
- 41 × v1 §4 扩展禁词命中
- 14 × 链式不一致
- 9 × ERROR:InvalidInputError
- 8 × special_pattern 隐藏降级
- 4 × JSON 解析失败
- 3 × 展开层含干支
- 1 × 换行转义双写
- 1 × environment_checklist 长度 3 != 期望 5

### 4o-mini 全部失败类别

- 40 × special_pattern 隐藏降级
- 8 × 链式不一致
- 3 × 分层失真
- 3 × 大运岁数与干支对不上
- 3 × 展开层含干支
- 2 × environment_checklist 长度 3 != 期望 5

