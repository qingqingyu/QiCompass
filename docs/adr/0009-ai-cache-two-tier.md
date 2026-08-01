# 0009 — AI 解读缓存 = 客户端 SwiftData + 后端 SQLite 两级(决策 4 / D2)

Status: accepted (2026-07-10)

AI 解读(深度解析 / 合盘 / 每日运势)是项目最大 provider 成本来源(每次 200-700 字输出)。两级缓存:

- **客户端 SwiftData** `InterpretationCache`:每用户设备缓存自己的解读,命中零延迟
- **后端 SQLite** `interpretation_cache`:跨用户共享,同出生信息的两用户命中同一缓存(content_hash 内容寻址最大价值)

缓存键 = `(content_hash, module, prompt_version, target_date?, provider, model)`。后端 SQLite 主键额外含渲染后 prompt 的 `prompt_hash`,防止相同业务 hash 携带不同 context 时互相污染。

**Why**:
1. 同用户重复打开 = 重复调上游(钱白烧 + UX 差)
2. 多用户同出生信息 = 各自调上游(content_hash 跨用户共享价值失效)
3. prompt 改了输出也变,旧缓存必须失效 → `prompt_version +1` 自然 miss
4. provider/model 切换 = 旧结果不能冒充当前模型缓存 → 身份必须进缓存键

**客户端身份解析**:三个 orchestrator 在读 SwiftData AI 缓存前先调 `GET /api/health`(请求 `reloadIgnoringLocalCacheData`),只读 provider/model 完全匹配的行。nil 旧行永不命中。`POST /api/interpret` 响应中的 provider/model 是最终生成身份;部署竞态导致它与此前 health 不同时,以 interpret 响应为准写入缓存。

**Surprising without context**: 客户端读 AI 缓存前居然要先打一次 health,看起来"过度设计",其实是为了避免部署期间 provider 切换后老缓存冒充新模型。

**Real trade-off**:
- ✅ 两级缓存 — 客户端零延迟 + 后端跨用户共享
- ❌ 仅客户端缓存 — 跨用户共享价值失效
- ❌ Redis — side project 阶段运维成本不该烧,v2 再说
- ❌ Singleflight — 用户数少并发同 hash 概率低,v2 再加

**Consequences**: prompt 改 → `prompt_version +1` 老缓存自然失效。lunar_python 升级(精度变化) → chart_hash 不变,建议清空缓存。详见 `命理引擎设计决策.md` §4。
