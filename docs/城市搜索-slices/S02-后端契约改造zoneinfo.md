# S02 后端契约改造(裸钟面 + timezone + zoneinfo + 删城市表)

- **类型**: AFK
- **Blocked by**: None — 与 S01 并行(后端不需要 SQLite,客户端发物理真值)
- **覆盖决策**: Q4(客户端发物理真值/删表/content_hash 物理量)/ Q5(zoneinfo 解释/fold 策略/boundary_warning)/ Q1(夏令时 IANA 历史规则)
- **Parent**: `docs/城市搜索设计决策.md`

## What to build

排盘 / 合盘「现排 B」的出生信息契约整体切换:

1. **请求模型**(`app/models/bazi.py` + `app/models/compatibility.py` person B 同步):
   - 删 `city: str|None`;`longitude`(必填范围校验 [-180,180])、`latitude`(存档,可选)、`timezone`(必填,合法 IANA 名,用 `zoneinfo.ZoneInfo(tz)` 校验)、`place_name`(展示,可选)、`geoname_id`(仅日志,可选)
   - `birth_datetime` 语义反转:validator 从「必须 offset-aware」改为「**必须裸时间(naive)**」,收到带 offset 的请求显式报错(错误显式传播,不静默剥 offset)
2. **时区解释(新 helper,`app/core/` 内)**:naive + `ZoneInfo(timezone)` → aware(fold=0);检测两类边角并降级 `boundary_warning`:
   - **歧义小时**(秋令时回拨重复段,`fold` 可 0/1)→ 取早 + warning「时间处于时制切换附近,请核对」
   - **不存在小时**(春令时跳过段,utcoffset 前后不一致)→ 按偏移平移 + 同款 warning
   - 实现注意:Python `zoneinfo` 无直接 API 判歧义,用 `dt.replace(fold=0/1)` 两算 `utcoffset()` 比对判断
3. **删城市表**:`app/core/city_longitude.py` 整文件删除,`resolve_longitude` 调用点(`bazi_engine.py:70` 附近、`compatibility.py:373`)改用请求内 `longitude`;引擎调用真太阳时的输入链路对齐
4. **真太阳时公式不动**:`true_solar_time.py` 保持 tz-invariant(已验证 UTC 抵消);`timezone_central_longitude` 输入改为解释后的 aware datetime
5. **content_hash 改归一化物理量**(`content_hash.py`):`(UTC 时刻, 经度固定精度字符串(如 "%.2f"), timezone, gender, zi_hour_rule)`——城市显示名不进 hash(北京 vs Beijing 不换盘);老 hash 全部失效,pre-launch 接受
6. **sync 契约**:`app/models/sync.py` `city_longitude` 旁增 `city_timezone`(及引擎响应里的对应字段),历史快照缺字段容忍(默认空)
7. **部署备忘**:后端容器化若用 Alpine 需系统 `tzdata`(当前 macOS/Linux 自带,零动作);写进 backend README 一行

## Acceptance criteria

- [ ] 旧格式请求(`city` 字段 / offset-aware `birth_datetime`)→ 422 显式报错带原因,不静默兼容
- [ ] 合法新格式(`naive + timezone="Asia/Shanghai" + longitude=116.41`)排盘结果与改造前北京盘**完全一致**(对盘回归)
- [ ] 1988-05-05 02:30 Asia/Shanghai(中国夏令时跳过段)→ 平移处理 + boundary_warning 含时制提示
- [ ] 1988-09-11 01:30 Asia/Shanghai(回拨歧义段)→ fold=0 + warning
- [ ] 1988-07-01 12:00 Asia/Shanghai → 自动按 +09:00(夏令时)解释,UTC 时刻正确
- [ ] 伦敦 BDST/美国 2007 前 DST 至少各 1 条历史用例通过(如 London 1945-07-01 双夏令 +02:00、US/Eastern 2005-10-30 EDT)
- [ ] `timezone: "Mars/Olympus"` 非法 IANA 名 → 422;`longitude: 200` → 422
- [ ] `CITY_LONGITUDE` / `resolve_longitude` 全仓 grep 零残留
- [ ] content_hash:同一 (UTC, 经度, tz, 性别, 规则) 稳定;place_name/geoname_id 变化不换 hash
- [ ] 现有 30 用例对盘全绿(fixtures 从 `+08:00` 格式改写为 naive + timezone,期望值不变)
- [ ] 合盘现排 B 走同契约,合盘对盘用例全绿

## 实现锚点(现状快照 2026-08-15,实施以代码为准)

- `backend/app/models/bazi.py:20-33` — `birth_datetime` Field + `must_be_timezone_aware` validator(语义反转)
- `backend/app/models/compatibility.py:33-49` — person B `birth_datetime` 同款 validator
- `backend/app/core/city_longitude.py:10-89` — `CITY_LONGITUDE` + `resolve_longitude`(整删)
- `backend/app/engine/bazi_engine.py:70` / `backend/app/engine/compatibility.py:373` — 调用点
- `backend/app/core/true_solar_time.py:37-42,54-87` — `timezone_central_longitude` / `compute_true_solar_time`(公式不动,输入链路对齐)
- `backend/app/core/content_hash.py:44-66` — hash 归一化重写
- `backend/app/models/sync.py:27` — `city_longitude` 契约
- `backend/tests/fixtures/shensha_cases.py` / `xiji_cases.py` — `+08:00` 格式 fixtures 批量改写

## 红线与约束

- **不擅自加依赖**:`zoneinfo` 是 Python 3.9+ stdlib,零新库
- **错误显式传播**:歧义/不存在小时不静默吞(必须出 warning);非法 tz/越界经度 422;naive 校验拒绝不剥 offset
- **零兼容垫片**:旧字段直接删,不写「city 或 longitude 二选一」过渡逻辑
- **确定性**:同 (UTC, lon, tz, gender, zi_hour_rule) → 同 hash 同输出;fold 策略固定 fold=0

## 测试

- `backend/tests/` 新增 `test_timezone_resolution.py`:历史规则(1986-91 中国 DST 三态:跳过/歧义/正常夏令)+ 伦敦 BDST + 美国 2007 前 DST + fold 策略 + 非法输入 422
- 改写现有 fixtures 至新契约,期望四柱/真太阳时值不变(对盘红线)
- content_hash 稳定性用例(place_name 变化不换 hash)
