prompt_versions 一致:是

| 指标 | GLM | DeepSeek | Claude | Luna |
|---|---|---|---|---|
| 模型身份(meta) | anthropic/glm-5.2 | openai/deepseek-chat | anthropic/claude-opus-5-5 | openai/openai/gpt-6-luna |
| verdict 分布 pass/warn/fail/error | 14/0/18/0 | 14/0/13/5 | 9/0/7/16 | 4/0/8/20 |
| **生产首调失败**(JSON+禁词+生成报错)/实际调用 | 1/32(3%) | 3/30(10%) | 10/26(38%) | 12/24(50%) |
|   JSON 解析失败 | 1 | 0 | 0 | 0 |
|   禁词命中 | 0 | 0 | 0 | 0 |
|   生成侧报错(含上下文超长) | 0 | 3 | 10 | 12 |
| 连带失败(上游坏导致未调用) | 0 | 2 | 6 | 8 |
| 红线:喜忌矛盾 | 0 | 0 | 0 | 0 |
| 红线:编造喜忌 | 0 | 0 | 0 | 0 |
| 红线:地支五行错置 | 0 | 0 | 0 | 0 |
| 红线:硬性格局 | 0 | 0 | 0 | 0 |
| 延迟 中位/P90/最大(秒) | 38.7/67.5/79.7 | 9.1/12.6/24.6 | 40.0/84.7/468.4 | 21.9/48.6/53.7 |

### GLM 全部失败类别

- 15 × special_pattern 隐藏降级
- 4 × 展开层含数字
- 2 × 展开层含干支
- 1 × structure_fingerprint 长度 108 超 40 字
- 1 × structure_fingerprint 长度 119 超 40 字
- 1 × structure_fingerprint 长度 120 超 40 字
- 1 × JSON 解析失败
- 1 × structure_fingerprint 长度 103 超 40 字

### DeepSeek 全部失败类别

- 11 × special_pattern 隐藏降级
- 5 × ERROR:InvalidInputError
- 4 × 展开层含数字
- 1 × structure_fingerprint 长度 123 超 40 字
- 1 × structure_fingerprint 长度 118 超 40 字
- 1 × structure_fingerprint 长度 113 超 40 字
- 1 × structure_fingerprint 长度 115 超 40 字

### Claude 全部失败类别

- 15 × ERROR:InvalidInputError
- 5 × 展开层含数字
- 4 × special_pattern 隐藏降级
- 1 × structure_fingerprint 长度 114 超 40 字
- 1 × ERROR:AIProviderError
- 1 × structure_fingerprint 长度 89 超 40 字
- 1 × 机器字段名外泄
- 1 × structure_fingerprint 长度 115 超 40 字
- 1 × structure_fingerprint 长度 153 超 40 字
- 1 × 展开层含干支

### Luna 全部失败类别

- 20 × ERROR:InvalidInputError
- 6 × special_pattern 隐藏降级
- 4 × 展开层含数字
- 3 × 展开层含干支
- 1 × structure_fingerprint 长度 90 超 40 字
- 1 × structure_fingerprint 长度 86 超 40 字
- 1 × structure_fingerprint 长度 161 超 40 字
- 1 × structure_fingerprint 长度 101 超 40 字

