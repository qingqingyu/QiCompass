# 模型 A/B 评测报告 · 2026-10-22

执行依据:`docs/model-ab-eval-handbook` 分支(280bb57)《模型选型AB评测-执行手册.md》。全程未触发停止条件。

## 1. 运行身份

- 仓库 commit:`9c6fcfb7f69014100aaee0f6ff0b89ccece5285c`(wenzi 分支;prompt_versions:m0=11,m1=5,m2=6,m3=6,m4=6,m5=5,m6=5,m7=5)
- GLM:provider `anthropic` / 真实型号 `glm-5.2` / base URL `https://api.z.ai/api/anthropic`
- **用户当前生产 `.env` 的 `ANTHROPIC_MODEL` 实际值:`glm-5.2`**——手册 §2 担心的「写成 claude-sonnet-4-6 贴错标签」情况不存在,本次 run 显式设置值与生产一致
- 候选:provider `openai` / 型号 `deepseek-chat` / base URL `https://api.deepseek.com/v1`;⚠️ DeepSeek 官方 API 回包的 `model` 字段为 **`deepseek-flash`**(官方端点对 deepseek-chat 的别名映射,记录在案)
- 裁判:provider `anthropic` / 型号 `claude-opus-5-5` / base URL `https://api.nuoda.vip`(**第三方中转,非 Anthropic 官方**;中转背后模型真实性无法核实,L3 分数带此保留);与哪一方同家族:**无**(既非 GLM 也非 DeepSeek)
- 各 run 的 meta.json identity 与上述一致:**是**(9 个 run 逐个核对:GLM 侧 `anthropic/glm-5.2`、候选侧 `openai/deepseek-chat`、裁判 `claude-opus-5-5`,无一处漂移)
- 网络重试过的条目:**0 条**。裁判侧网络层失败共 5 条(GLM run 4 × `Anthropic API HTTP 524`、候选 run 1 × `RemoteProtocolError`)——**未补跑**,原因:runner 无单条补跑机制(`--case-limit` 只能整盘重跑,会重新生成内容,违反「不重跑到通过」);生成侧网络失败 0 条。这 5 条生成数据完好,仅缺 L3
- 实际调用量:生成 421 + 裁判 234 = **655 次**(预算上限 800,未超);冒烟阶段 `ab-smoke-judge` 因复用 `ab-smoke-glm` 的响应缓存只发了 1 次生成调用(cache_hits=7)

## 2. 简体全量对比(160 条)

| 指标 | GLM(glm-5.2) | 候选(deepseek-chat) |
|---|---|---|
| pass / warn / fail / error | 63 / 21 / 41 / 35 | 65 / 57 / 25 / 13 |
| JSON 解析失败 | 8 | 0 |
| 普通盘 pass 率 | 53/120(44%) | 47/120(39%) |
| special_pattern 盘 pass 率 | 10/40(25%) | 18/40(45%) |
| 延迟中位 / P90 / 最大(ms) | 36,435 / 53,016 / 89,545 | 10,166 / 19,983 / 26,294 |
| 本次 token / 费用 | 未取得(无控制台访问,不估算) | 未取得(同左) |
| 生成侧调用次数(api_calls) | 132(链断少调 28) | 160 |
| 裁判调用次数(judge_calls) | 91 | 135 |
| run 总时长 | 98.4 min | 42.0 min |

生成侧 error 结构(影响上面 error 计数):GLM 35 条 error 中 **31 条为生成侧**(case_14 M0 fail → 下游 7 条「链路中断」+ M0 输出缺下游链字段 → 24 条 `InvalidInputError: prompt 渲染缺字段`),4 条为裁判侧;候选 13 条 error **全部为裁判侧**,生成侧 0 条。

### 2.1 按模块 pass 率(严格 pass 口径,不含 warn)

| 模块 | GLM | 候选 |
|---|---|---|
| m0_structure | 7/20 | 8/20 |
| m1_talent | 10/20 | 12/20 |
| m2_high_low | 8/20 | 7/20 |
| m3_system | 7/20 | 6/20 |
| m4_health | 9/20 | 5/20 |
| m5_wealth | 9/20 | 15/20 |
| m6_dynamics | 8/20 | 7/20 |
| m7_manual | 5/20 | 5/20 |

按模块延迟(中位秒,GLM / 候选):m0 31.0/6.0 · m1 36.8/10.4 · m2 44.6/11.7 · m3 40.3/13.1 · m4 36.4/9.8 · m5 60.2/22.0 · m6 34.0/8.6 · m7 29.2/8.7(GLM m5_wealth 中位 60 秒为全场最慢)。

### 2.2 L1/L2 failure Top 10(各自,原样引用文案并计数)

**GLM:**

| 次数 | failure 文案(长原文截断) |
|---|---|
| 12 | 生产禁词命中:['绝对'] |
| 12 | special_pattern 隐藏降级:全文未出现「不入常格/从格/专旺/特殊格局」类诚实表述(后端喜忌留空的原因必须告知用户) |
| 5 | JSON 解析失败:LLM 输出非合法 JSON:Expecting ',' delimiter(各 1 次,截断点分别在 char 815/1305/1785/2048/3862) |
| 1 | 展开层含数字:capability_source.text 出现「0」(权重/计数等数字只进据类字段,年龄除外) |
| 1 | 展开层含干支:core_loop.leak 出现「戊土」(干支只许出现在「约 X 岁起的那十年」括注里) |
| 1 | 展开层含干支:core_loop.leak 出现「巳火」(同上) |

**候选:**

| 次数 | failure 文案(长原文截断) |
|---|---|
| 14 | special_pattern 隐藏降级:全文未出现「不入常格/从格/专旺/特殊格局」类诚实表述(后端喜忌留空的原因必须告知用户) |
| 3 | 照抄示例:输出含示例短语「能跑的版本」(示例只演示写法,不得复用) |
| 2 | 喜忌矛盾:文本「补五行金」推荐 金,但后端 unfavorable=['水', '金'] |
| 1 | 展开层含干支:core_loop.leak 出现「未土」 |
| 1 | 展开层含干支:core_loop.leak 出现「寅木」 |
| 1 | 展开层含数字:core_loop.leak 出现「1」 |
| 1 | 展开层含数字:core_loop.leak 出现「3」 |

### 2.3 L3 七维平均分(配对条目数 = 68;GLM 被裁 84 条、候选被裁 122 条)

| 维度 | GLM | 候选 |
|---|---|---|
| 五行完整 | 4.31 | 3.82 |
| 十神配置 | 4.59 | 4.22 |
| 神煞准确 | 3.21 | 2.54 |
| 大运流年 | 3.44 | 2.66 |
| 无硬性格局 | 5.00 | 5.00 |
| 严格遵守后端喜忌 | 4.84 | 4.56 |
| special_pattern_诚实(n=8) | 4.50 | 4.75 |
| **overall** | **4.24** | **3.81** |

裁判侧数据质量备注:裁判输出格式异常共 15 条(GLM run 3 条:2 缺维度「神煞准确」+ 1 未知维度「special_pattern_诚失」;候选 run 12 条:9 缺「神煞准确」+ 3 缺「大运流年」),这些条目生成侧完好、仅 L3 缺失,未计入配对。

## 3. 三语抽查(4 盘 × 8 模块;判据按简体设计,verdict 仅参考,评审请读原文)

| run | pass / warn / fail / error | JSON 解析失败 |
|---|---|---|
| ab-glm-en | 14 / 0 / 18 / 0 | 1 |
| ab-cand-en | 14 / 0 / 13 / 5 | 0 |
| ab-glm-zh-hant | 6 / 0 / 15 / 11 | 2 |
| ab-cand-zh-hant | 9 / 0 / 23 / 0 | 0 |

## 4. 执行者的主观观察(主观,有限抽样:仅抽读 6 个文件,未逐条精读;不构成换型建议)

- 简体 case_15(从格盘)m0:两边都有诚实降级表述——GLM「旺衰标注为『从格特征』,引擎未下喜忌结论」;候选「引擎标为从格特征,喜忌候选为空」。「隐藏降级」failure 集中在其他盘,原文见各 run 目录。
- 英文 m1_talent(case_00):两边英文都通顺,风格有别——GLM 偏克制名词化("Private deep-dive research"),候选偏叙事铺陈("Private research that goes deeper than the room")。
- 繁体:候选抽样输出(m0 body)为正经繁体用字(主見/夥伴/鋒芒);GLM zh-hant run 有 11 条 error(含 2 条 JSON 解析失败),原 case_15 的 m0 `response.json` 缺失(文件不存在,失败原因见该 run `results.jsonl`)。
- GLM 的 8 条 JSON 解析失败文案全部是 `Expecting ',' delimiter`,截断点多在 char 800-4000,与超长输出截断的形态相似但本次未逐条核实是否 max_tokens 所致(原文与 results.jsonl 均在交付内,可核)。

## 5. 异常与偏差(所有未严格按手册执行处/存疑处)

1. **裁判网络失败 5 条未补跑**:手册允许「网络层失败对同一条最多补跑一次」,但 runner 不支持按条重跑,整盘重跑会重新生成内容(违反硬性规则 6「不重跑到通过」),故如实保留。若评审需要,这 5 条可单独安排补裁。
2. **裁判输出格式异常 15 条**(明细见 §2.3 备注):裁判为经第三方中转的 claude-opus-5-5,偶发漏维度/错字。L3 统计已按「有分才算」自然剔除,未做任何修补。
3. **BASELINE 已存在**:worktree `backend/evalkit/runs/` 下已有历史 run ×3 与 BASELINE(20261016,judge=glm-5.2,m0 v10)。按硬性规则 2 未删未用未改。runner 自动与它对比报 regressed=42(GLM)/18(候选)——该对比身份不对齐(judge 不同、m0 模板 v10→v11),**不作为本报告结论依据**,仅背景记录。
4. **dry-run 160/160 通过但真跑出现 24 条 `InvalidInputError`**:dry-run 不调 AI,M0 下游链字段来自模型真实输出,缺字段只能在真跑暴露。两边同条件受试,公平性不受影响,但说明 dry-run 不能预言链完整性。
5. 候选模型 API 回包 `model=deepseek-flash`(deepseek-chat 的官方别名),发起侧始终用 `deepseek-chat`。
6. 裁判走第三方中转 `api.nuoda.vip`,非 Anthropic 官方端点;已在 §1 标注。
7. 冒烟实际调用量低于手册预算估计:ab-smoke-judge 命中 ab-smoke-glm 的响应缓存(生成 1 + 裁判 8);另开跑前用 2 次微调用(max_tokens=8)探针确认了两家端点与型号名可用(手册未列此步骤,零成本排障,记录在案)。
8. 停止条件触发:**0 次**(dry-run、三份冒烟、两个全量、四个三语 run 全部走完;三语脚本未出现 import/模板错误)。
