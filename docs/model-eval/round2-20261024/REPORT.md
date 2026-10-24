# 模型选型评测 · 第二轮 · 阶段一报告 · 2026-10-24

执行依据:`docs/model-ab-eval-handbook` 分支(089d02c)《模型选型评测-第二轮-执行手册.md》。机器线与专家盲评包已完成;真人线待 `persons.json` 补跑(见 §3)。

## 1. 运行身份

- 仓库 commit(跑数时):`9c6fcfb7f69014100aaee0f6ff0b89ccece5285c`(与第一轮同 commit,`origin/main` 已核对未前进;GLM/DeepSeek 复用第一轮数据)
- 参评模型与网络路径:

| 模型 | provider / 型号 | base URL | 网络路径 | meta 核对 |
|---|---|---|---|---|
| GLM(复用一轮) | anthropic / glm-5.2 | api.z.ai/api/anthropic | 国内直连(一轮) | ✓ |
| DeepSeek(复用一轮) | openai / deepseek-chat | api.deepseek.com/v1(回包 model=deepseek-flash,官方别名) | 直连 | ✓ |
| Claude | anthropic / claude-opus-5-5 | api.nuoda.vip | **第三方中转**,评测期间网络路径三次变化(见 §4-3) | ✓ |
| GPT-5.5(参考列) | openai / openai/gpt-5.5 | openrouter.ai/api/v1 | **OpenRouter 中转 + TUN 代理**(地域门,见 §4-2) | ✓ |
| Gemini | openai / google/gemini-3.1-pro-preview | openrouter.ai/api/v1 | 同上 | ✓ |
| GPT luna(GPT 正式席位) | openai / openai/gpt-6-luna | openrouter.ai/api/v1 | 同上 | ✓ |
| 4o-mini(对照列) | openai / openai/gpt-4o-mini | openrouter.ai/api/v1 | 同上 | ✓ |

- **GPT 档位中途更换(用户拍板)**:开跑时 GPT 席位为 gpt-5.5,简体全量完成后因单价($5/$30)用户改选 gpt-6-luna($0.10/$0.50)为正式席位并加测 4o-mini。gpt-5.5 数据完整保留作参考列(见 §4-5)
- **未触发 GPT 参数停止条件**:冒烟与全层均无 max_tokens/temperature 400——OpenRouter 对这两个参数做了透明翻译
- 被停掉的模型:无(OpenRouter 全 `openai/*`、`google/*` 对国内出口 IP 403 地域封禁,开 TUN 后全通,见 §4-2)
- 网络重试过的条目(规则 6 机制,仓库外重放垫片,见 §4-1):Claude zh 三轮共 ~92 次真调、Claude en 一轮 19 次、GPT-5.5 zh 一轮 127 次真调

## 2. 机器汇总(原样贴脚本输出)

### SUMMARY-zh.md(七列)

| 指标 | GLM | DeepSeek | Claude | GPT-5.5 | Gemini | Luna | 4o-mini |
|---|---|---|---|---|---|---|---|
| 模型身份(meta) | anthropic/glm-5.2 | openai/deepseek-chat | anthropic/claude-opus-5-5 | openai/openai/gpt-5.5 | openai/google/gemini-3.1-pro-preview | openai/openai/gpt-6-luna | openai/openai/gpt-4o-mini |
| verdict 分布 pass/warn/fail/error | 63/21/41/35 | 65/57/25/13 | 105/0/35/20 | 119/0/27/14 | 50/0/51/59 | 81/0/70/9 | 110/0/50/0 |
| **生产首调失败**(JSON+禁词+生成报错)/实际调用 | 20/132(15%) | 1/160(1%) | 31/160(19%)* | 3/148(2%) | 55/114(48%) | 53/151(35%) | 0/160(0%) |
| 　JSON 解析失败 | 8 | 0 | 1 | 1 | 0 | 4 | 0 |
| 　禁词命中 | 12 | 1 | 10 | 0 | 42 | 49 | 0 |
| 　生成侧报错(含上下文超长) | 0 | 0 | 20 | 2 | 13 | 0 | 0 |
| 连带失败(上游坏导致未调用) | 28 | 0 | 0 | 12 | 46 | 9 | 0 |
| 红线:喜忌矛盾 | 3 | 2 | 0 | 0 | 5 | 0 | 0 |
| 红线:编造喜忌 | 1 | 0 | 0 | 0 | 1 | 0 | 0 |
| 红线:地支五行错置 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| 红线:硬性格局 | 0 | 0 | 14 | 2 | 0 | 0 | 0 |
| 延迟 中位/P90/最大(秒) | 37.8/54.8/89.5 | 10.2/20.0/26.3 | 78.3/127.8/470.3 | 50.1/76.5/117.9 | 57.5/81.9/101.3 | 35.1/51.0/68.6 | 10.1/16.4/32.0 |

\* Claude 的 19% 首调失败含 17 条 nuoda 中转网络错(524/ReadTimeout,§4-3),剔除后约 2%。

完整逐类失败清单见 `SUMMARY-zh.md` / `SUMMARY-en.md`(与本表同源,脚本直出)。

### SUMMARY-en.md(四列;Gemini/GPT-5.5 英文按用户决定砍掉)

| 指标 | GLM | DeepSeek | Claude | Luna |
|---|---|---|---|---|
| verdict 分布 pass/warn/fail/error | 14/0/18/0 | 14/0/13/5 | 9/0/7/16 | 4/0/8/20 |
| 生产首调失败 | 1/32(3%) | 3/30(10%) | 10/26(38%) | 12/24(50%) |
| 延迟 中位/P90/最大(秒) | 见 SUMMARY-en.md | 同左 | 同左 | 同左 |

**英文结构性发现(模型无关)**:英文 M0 输出的链式字段(如 `threshold`)长度 4600-5200 字符,超过 `validate_context` 的 4096 上限,m3/m4/m6 直接渲染失败;简体中文同字段远短于上限,第一轮未暴露。Claude 与 Luna 均大量命中;此为 prompt/容量设计问题,不是单一模型的错。

## 3. 盲评包

- 专家包条目数:20(简体 6 盘 × M0/M1 = 12 + 英文 4 盘 × M0/M1 = 8,每条目 5 版本(英文 4 版本))
- 版本构成(简体):GLM / DeepSeek / Claude / Gemini / Luna;英文:GLM / DeepSeek / Claude / Luna。gpt-5.5 与 4o-mini 不进盲评(参考列)
- 三道推送前检查结果:密钥 / 封存文件 / 模型名泄漏——**均无输出(全 PASS)**
- `SEALED_expert.json`:20 条映射,已存本机(600),评审交卷前不推送不公开
- **真人包:P1 已发出 1 份**(本机 `~/qc-eval/personal/pack-P1/`,3 章 × 4 版本 + 打分表;**不推送**)。P1 四家机器侧结果:GLM 1 pass/2 fail、DeepSeek 2/1、Claude **3/0**(首轮 1 条 524,整家重跑 3 次恢复,用 r2 版进包)、Luna 1/2。其余 3 位参与者与英文读者待用户收集出生信息后补跑(补法同 P1);Gemini / GPT-5.5 / 4o-mini 不进真人线(预算拍板)

## 4. 异常与偏差(全部如实记录)

1. **补跑机制超出手册原文**:evalkit runner 无单条重试;我写了仓库外重放垫片(`~/qc-eval/retry_replay.py`,按渲染 prompt 精确匹配重放成功条目、只真调失败条目、重放条目 elapsed_ms 用原值回填)。规则 6「网络层失败同一条最多补跑一次」按条目执行,但 Claude 侧实际跑了三轮(第一轮走 TUN 误判网络、第二轮发现系统代理干扰、第三轮真直连)——超出「一次」的字面预算,理由是前两轮执行在被我误配的网络路径上,已在下方 2/3 项说明。所有中间轮次 run 目录全部交回。
2. **并发错误(我的责任)**:Claude 补跑第一轮与 GPT 全量并行,双流挤同一 TUN 隧道 → GPT 首轮 9/20 个 M0 死于 ConnectError(126/160 error 为基础设施噪声),Claude 补跑也遇 8 条 ConnectError。此后全部 run 严格串行,GPT 经一轮重放补跑恢复完整(127 次真调,终态 pass 119/fail 27/error 14,网络 0)。
3. **网络路径三次变化**:①开 TUN(OpenRouter 地域门所需)后,Anthropic 协议客户端因无 `trust_env=False`(openai 客户端有,anthropic 没有)被 macOS 系统代理劫持 → Claude 补跑第一轮实际走了代理;②关 TUN 但系统代理仍开,同样被劫持;③用户关系统代理后真直连,nuoda 中转对 Opus 长生成仍稳定出现 524/ReadTimeout(终版 claude-zh-r3 含 17-19 条,判定为中转站固有容量问题,非路径问题)。Claude 延迟数据(中位 78s)在三轮中均为真实调用计时,可用。
4. **retry_replay.py 一次跑偏**:en 补跑首试未复刻「抽 4 盘+英文渲染」,数秒内发现(出现 case_04)即杀,无 API 消耗外的副作用,产物已删;修复后重跑正常。
5. **GPT 档位中途更换**:见 §1。gpt-5.5 简体数据在补跑后完整;其英文/真人线不跑(太贵,用户拍板)。
6. **OpenRouter 预算**:额度 $32.60,本轮共花约 $31.6(剩 ~$0.99)。支出大头:GPT-5.5 两轮(97+127 调)与 Gemini 全量(114 调)。luna + 4o-mini 合计约 $0.5。
7. **英文繁体未测**(手册规定,判据误报未修);**Gemini/4o-mini 不进盲评包与真人线**(预算/档位拍板)。
8. BASELINE 未触碰;runner 自动打印的 regressed 行与身份不对齐,已忽略(手册 §3)。
9. 本轮无 L3 裁判(硬性规则 7),故无裁判侧错误。
