# S01 后端 hour_known 契约 + 三柱排盘 + 喜忌 unknown_hour(tracer bullet)

- **类型**: AFK
- **Blocked by**: None — 可立即开始(与 S03 并行)
- **覆盖决策**: D4(喜忌 unknown_hour 复用从格先例)/ D3 后端半边(late_night 日柱歧义)/ 契约与护栏备注全部(hour_known 唯一事实源 / 12:00 占位 / pillars.hour null / calc_rule_snapshot / content_hash)
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

单盘 `/api/bazi` 端到端支持时辰未知,一条请求走通:

1. **请求模型**(`app/models/bazi.py`,`extra="forbid"`):
   - `hour_known: bool = True`(默认值必须,否则老客户端 422)
   - `late_night: bool | None = None`(三态:True=是 / False=否 / None=不确定)
2. **排盘链路**(`bazi_engine.py`):
   - `hour_known=false` → `birth_datetime` 时辰部分统一替换为 **12:00 占位**喂 `lunar_python`(离 23:00 换日与 00:00 两个边界最远);响应 `pillars.hour` 置 `null`,`Pillars.hour` 改 Optional;**五行统计按三柱 6 字计**(计数口径 8→6,`element_balance` 各值之和为 6,响应自然呈现,不另加标注字段)
   - `late_night` 日柱歧义:`hour_known=false` 且 `late_night != False`(即 True 或 None)→ **日柱也置 unknown**(响应表达:day 柱歧义标记,日主相关派生输出置空);`late_night=False` → 日柱照常计算。判定窗口定义按该出生地真太阳时 `offset_minutes` 反算墙钟(参考 `true_solar_time.py` `boundary_crossed`),窗口定义写进模型 docstring,**不硬编码 23:00-24:00**
3. **喜忌引擎**(`xiji.py`):入口处加 unknown_hour 分支——时柱缺失或日柱歧义 → `day_master_strength="unknown_hour"`,favorable/unfavorable 留空。与从格 `special_pattern`(`xiji.py:240` 附近)完全同构:引擎不硬算,显式降级。日柱歧义时日主无,`day_master` 系派生字段一并置空
4. **神煞**(`shensha.py`):按可用柱查(时柱缺失则无时支条目),响应加神煞完整性标注(如 `shensha_incomplete: true`),不静默
5. **`calc_rule_snapshot`**(`app/core/calc_rule_snapshot.py`):加 `hour_known`(缺字段则「同一输入永远同一输出 + 快照可审计」被破坏)
6. **content_hash**(`app/core/content_hash.py`):`hour_known=false` 时 2h 时辰桶**不参与**,日期 + `late_night` + 歧义标记(S02)参与;`hour_known=true` 路径 hash 公式不变。注:Parent 契约备注只写了「日期(含 D10 歧义标记)」,本系列把 `late_night` 补进 hash 是必要扩展——`late_night` 决定日柱歧义状态,不同答案输出不同,不进 hash 会同 hash 不同输出(缓存碰撞),并非对 Parent 的笔误
7. **大运**(`luck.py`):干支序列与起运年龄**照给**(已知弱依赖误差 ±2-3 个月,v1 接受不加标注)

8. **`ChartPayload` 契约同步扩**(2026-09-01 review 补入,原分割漏项——**没有任何 slice 拥有它,而 S09 依赖它**):
   - `app/models/daily_fortune.py` `ChartPayload.day_master_strength` 的 `Literal` 加 `"unknown_hour"`;`four_pillars` 的 `hour` 键改可缺省(`dict[str, PillarRef]`,校验从「必含 year/month/day/hour」放宽为「必含 year/month/day」)
   - 该模型被 **每日运势与合盘共用**(`DailyFortuneRequest.chart_payload`,`daily_fortune.py:85`;`compatibility.py:99-101` 的 `chart_payload_a/b`)。不扩则无时辰盘**连每日运势请求都发不出去**(422),而每日运势是默认落地 Tab(`RootTabView.swift:20`)——一期就会撞上,不是二期问题
   - 合盘的 `PersonBInput`(`app/models/compatibility.py:33`)本 slice **不动**(模式 B 临时输入走 S11 的发起前拦截,请求永不携带无时辰盘)

合盘 `PersonBInput` 契约本 slice **不动**(默认 true 路径,不传字段零影响),归 S11。

## Acceptance criteria

- [ ] 老客户端请求(不传 hour_known/late_night)→ 响应与现状**逐字段一致**(回归对拍)
- [ ] `hour_known=false, late_night=false` → `pillars.hour=null`、日柱/年月柱正常、`strength="unknown_hour"`、喜忌两列表空、神煞无时支条目 + 完整性标注、大运序列照给(对盘样例取东八区中部经度,如 116°E;西偏经度的日柱歧义场景由 S02 覆盖,勿在本用例混入)
- [ ] `hour_known=false, late_night=true` 与 `late_night=null` → 日柱 unknown 标记 + 日主派生输出置空
- [ ] `hour_known=false` 时 `birth_datetime` 的时辰部分无论传什么(06:13 / 23:40),输出一致(12:00 占位生效,占位不漏到响应)
- [ ] `calc_rule_snapshot` 含 `hour_known`;同出生信息 `hour_known` true/false → 不同 content_hash;`hour_known=false` 下 `late_night` true/false/null 三态 → 三个不同 hash
- [ ] 现有 pytest 全绿 + 新增 unknown_hour 用例(含对盘:三柱部分与已知盘比对,时柱/喜忌按 unknown 断言)
- [ ] `pytest` 里含「占位 12:00 恰不跨换日边界」的样例(如正午出生日 vs 无时辰同日,日柱相同)
- [ ] `ChartPayload` 接受 `day_master_strength="unknown_hour"` 且 `four_pillars` 缺 `hour` 键 → 不 422;`hour` 存在的老请求逐字段回归一致
- [ ] `/api/daily-fortune` 收无时辰 `chart_payload` → 不 422(内容侧行为归 S07 一期拦截 / S09 二期降级,本 slice 只保证契约层通)

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `backend/app/models/bazi.py` — 请求模型 + `must_be_naive` validator(格式不动,只加字段)
- `backend/app/engine/bazi_engine.py:80-96` — setSect(1) 换日 / 生肖推导(94)
- `backend/app/engine/xiji.py:30` `DELING_WEIGHT=5` / `:126-154` 扶抑 / `:240` 附近 special_pattern 降级先例
- `backend/app/engine/pillars.py:127-144` 五行统计(时柱缺失时按 6 字口径)
- `backend/app/engine/shensha.py:33-46` 四柱遍历查神煞
- `backend/app/engine/luck.py:10-38` 大运起排
- `backend/app/core/calc_rule_snapshot.py` — 现无 hour_known 字段
- `backend/app/core/content_hash.py:27-45` — 2h 时辰桶
- `backend/app/core/true_solar_time.py:69,76-90` — offset / `boundary_crossed`
- `backend/app/models/daily_fortune.py:44,46,85` — `ChartPayload` Literal / `four_pillars` / `DailyFortuneRequest`
- `backend/app/models/compatibility.py:99-101` — `chart_payload_a/b`(同一模型的另一消费者)

## 红线与约束

- 老客户端零破坏:缺省字段走原路径,禁双格式兼容垫片
- 不猜:日柱歧义显式置 unknown,禁止取中点/默认时辰
- 错误显式传播:神煞不完整要标注,不静默少给
- 零新依赖

## 测试

- `backend/tests/` 新增 `test_hour_unknown.py`:三态 late_night / 占位一致性 / hash 分叉 / snapshot 字段 / 回归对拍
- 现有对盘用例全部保持绿(未传新字段的路径)
