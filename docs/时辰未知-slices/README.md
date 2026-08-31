# 「不知道出生时刻」全链路 — 实施分割索引

Parent 设计事实源:`docs/时辰未知设计决策.md`(D1-D10,ACCEPTED 待实施;含 2026-08-31 review 回填终版)。
本目录为 2026-08-31 to-issues 分割产物:11 个 vertical slice(一期 8 + 二期 3),9 AFK + 2 HITL,每个独立可 demo/验收。

## 实施顺序

| Slice | 标题 | 类型 | Blocked by | 一句话 |
|---|---|---|---|---|
| S01 | [后端 hour_known 契约 + 三柱排盘 + 喜忌 unknown_hour(tracer bullet)](S01-后端hour_known契约与三柱排盘.md) | AFK | 无 | API 收 `hour_known=false` → 12:00 占位、`pillars.hour=null`、strength=unknown_hour、喜忌留空、深夜日柱歧义;老客户端零变化 |
| S02 | [D10 节气边界双排盘比对](S02-D10节气边界双排盘比对.md) | AFK | S01 | 00:00/23:59 探针比对年/月柱 + 日柱歧义网(排除换日窗的主体区间判定,防探针退化);立春→生肖未知;节交界→调候/得令/大运序列不可用;日柱歧义→D5 全拦截分支 |
| S03 | [iOS 表单拆双 picker + 日期必选](S03-iOS表单拆双picker与日期必选.md) | AFK | **无(与 S01/S02 并行)** | 纯数据质量修复(hour_known 恒 true),birthDate Optional 化,日期未触碰不能提交 |
| S04 | [iOS「不知道出生时刻」入口 + 二值半夜问题](S04-iOS时辰未知入口与半夜问题.md) | AFK | S01、S03 | checkbox 收起时刻输入 + 「是否半夜出生」三态 + hour_known/late_night 提交 + payload 存档 |
| S05 | [iOS 三柱盘展示 + 时柱列留白](S05-iOS三柱盘展示与时柱留白.md) | AFK | S01(可与 S04 并行) | DTO hour Optional 化、PillarsTable/DualPillarsTable 留白 dashed 触点、PromptContextBuilder unknown 分支 |
| S06 | [深度解析免费 2 章降级叙事(prompt)](S06-深度解析免费2章降级叙事prompt.md) | **HITL** | S01 | bazi_deep_free 模板 unknown_hour 分支 + PV bump + 双护栏;HITL 因 evalkit 首轮基线未定 + 文案 voice 需真人过目 |
| S07 | [iOS 付费墙拦截(一期临时态)](S07-iOS付费墙拦截临时态.md) | AFK | S04、S05、S06 | 付费 8 章临时全拦 + 合盘任一方无时辰整对拦(免费亦拦,后端契约算不出):不展示价格、不触发 purchase、「补充出生时刻后解锁」 |
| S08 | [生肖屏立春降级路径](S08-生肖屏立春降级路径.md) | AFK | S02、S04 | 年柱歧义 → 生肖屏告知「需时辰才能确定属相」+ 补时辰入口占位,不猜 |
| S09 | [每日运势降级版 prompt](S09-每日运势降级版prompt.md) | **HITL** | S01、S06 | REQUIRED_FIELDS 收窄 + 日柱×流日叙事 + 三边同步 + evalkit;日柱歧义者每日运势全拦 |
| S10 | [补时辰升级闭环](S10-补时辰升级闭环.md) | AFK | S07、S09 | 只补时辰 sheet + 三触点接线 + 「我确实不知道」静默态 + hash 重建老盘归档 |
| S11 | [合盘 roster「不可合盘」标记](S11-合盘roster不可合盘标记.md) | AFK | S05、S04(二期,可与 S07 并行开工) | 自己无时辰→全部对不可用;他人无时辰→该对不可用(发起前拦截,与 S07 整对拦判据同源);双方有时辰对保持现状 |

## 一期 = S01-S08,二期 = S09-S11(对齐决策 D9)

每期可独立验收;一期结束 = 无时辰用户可以诚实建档、看到三柱盘 + 免费 2 章降级叙事、付费被拦、生肖屏安全;二期结束 = 每日运势降级、付费墙拦截页文案适配(S10 落地,S07 临时态 → 正式版)、补时辰闭环、合盘标记。

## 全系列红线(每个 slice 文档内均有)

- **契约红线**:`hour_known: bool = True` 默认(请求模型 `extra="forbid"`,老客户端不传字段零 422);`birth_datetime` 保持现有 naive ISO 格式,`hour_known=false` 时后端统一喂 **12:00 占位**(离两个换日边界最远);`pillars.hour` 置 null 表缺失;`calc_rule_snapshot` 必须带 `hour_known`(否则「同一输入同一输出 + 快照可审计」被破坏)
- **老客户端零破坏**:不传新字段 → 走原路径,响应与现状一致(逐字段回归对拍);pre-launch 无存量用户,不做双格式兼容垫片
- **错误显式传播 / 不猜**:日柱(late_night)、年月柱(S02 节气)、生肖歧义一律显式标记未知,**禁止**默认值/取中点/猜一个——歧义标记进响应 + content_hash
- **content_hash**:`hour_known=false` 时 2h 时辰桶不参与,日期 + `late_night` + 歧义标记参与(`late_night` 是对 Parent 契约备注「日期(含 D10 歧义标记)」的必要扩展——它决定日柱歧义状态,不进 hash 会同 hash 不同输出);补时辰 → hash 变 → 新命盘(决策 D7)
- **iOS payload 教训**:ChartSnapshot / DTO 新字段(`hour_known` / `late_night` / 歧义标记)一律 `decodeIfPresent`(2026-08-15 老盘 keyNotFound 教训)
- **prompt 双护栏(CLAUDE.md)**:动 `app/ai/prompts.py` 模板必须 `tools/check_prompt_sync.py` PASS + evalkit 无 regression + bump `PROMPT_VERSIONS`;PV 策略:S06 bump `bazi_deep_free`(`bazi_deep` / `bazi_deep_paid` 同 bump,同次产品迭代)、S09 bump `daily_fortune`,各一次,后续 slice 不再 bump
- **LLM 边界**:`unknown_hour` 状态由后端确定性引擎给出,LLM 只诚实叙述「时辰未知,喜忌分析需准确时辰」,禁止自行推断喜忌或编造时柱影响
- **不擅自加依赖**:后端零新库(iOS 系统控件、后端纯 Python);不引入分词/正则替换类方案
- **i18n**:iOS 新文案跟随现状走 L10n / `Localizable.xcstrings`(中英双语)
- **视觉**:一切 UI 决策先读 `DESIGN.md`(水墨孤本语言;时柱列留白 + dashed hairline 复用「锁定/临时态」语义,不是错误提示)
- **大运弱依赖**:起运年龄由节气时间差换算,无时辰时漂移 ±2-3 个月——**v1 接受此误差照给**,不加标注字段(决策依赖表「弱依赖」)

## 不做(勿在本系列实现)

人格题反推(D2)/ 按章节部分售卖(D5 写死不做)/ entitlement 重绑(mismatch_reject 独立课题,决策 D7)/ 兑换码拦截(无此决策,redeem 是 StoreKit 同步端点)/ 候选时辰共识盘(存档 `late_night` 供未来,本期不做)/ 时段四段选择(已否决)/ 大运起运年龄误差标注。
