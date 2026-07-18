# 付费系统设计决策(MONETIZATION)

Generated on 2026-07-18, last updated 2026-07-18
Status: DRAFT(待用户 review 通过,通过后转 ACCEPTED)
关联文档: `CLAUDE.md` / `bazi-app-design-doc.md` / `命理引擎设计决策.md` / `DESIGN.md`

## 设计哲学

跟 `DESIGN.md` 的 "专业不忽悠,不像算命软件" 完全对齐。付费模式必须:

- **诚实**:免费章节也是真 AI 内容(不是占位/缩水版),用户买之前能感知"AI 真有料"
- **可预期**:用户买之前明确知道能看什么章节,不靠模糊宣传
- **不连续付费骚扰**:**消耗型 IAP**,每次新命盘单独购买,不做订阅/月费/自动续费
- **越狱不可白嫖**:**后端 entitlement 校验**,iOS 绕过 UI 也拿不到付费内容(后端不返回)
- **价格诚实**:$18 单价对应"深度、定制、不水"的承诺,不做低价走量套路

## 决策汇总(已锁定 2026-07-18)

| 决策点 | 选择 | 理由 |
|---|---|---|
| Entitlement 模型 | **消耗型 IAP per-命盘** | 用户原话"修改生辰要重新购买";严格按 `content_hash` 绑定,每次新增/修改命盘都消耗一次购买 |
| 深度解析免费章节 | **性格底色 + 事业(2 章)** | 用户能从免费内容感知"AI 真有料"才肯买 |
| 深度解析付费章节 | **财运 / 爱情 / 健康 / 六亲 / 晚年(5 章)** | 具体领域预测是用户付费动力 |
| 合盘付费形态 | **跟深度解析同形态(半免费)** | UX 一致,降低实现复杂度 |
| 每日一问 | **开放问题 + 留历史** | 留历史提升回访率,与"每日运势"形成"看运势 → 提具体问题"的链路 |
| 定价基准 | **深度解析 $17.99 / 合盘 $11.99(USD)** | 高端定位,跟 `DESIGN.md` 的"克制、专业"对齐;合盘内容更少所以更便宜 |
| 上架区域 | **全球,苹果 Price Tier 自动换算(基准 $17.99/$11.99)** | 苹果自动按 Tier 处理汇率,文案保持中文(v1 范围) |
| 后端校验 | **接 App Store Server API + 退款 webhook** | 越狱不可白嫖,收入保护优先;v1 用户量虽小但此基础设施一次建好,v2 复用 |

## 商品 SKU 列表

| product_id | 类型 | 基准价 | 苹果 Tier(估) | 备注 |
|---|---|---|---|---|
| `com.qicompass.deep_analysis.single` | Consumable | $17.99 | Tier 60 | 单次深度解析解锁,绑定到一个 `content_hash` |
| `com.qicompass.compatibility.single` | Consumable | $11.99 | Tier 35 | 单次合盘解锁,绑定到一个 `compatibility_hash` |

**苹果 Price Tier 自动换算**(苹果按 Tier 算,开发者不逐市场设):
- 美区:$17.99 / $11.99
- 中国区:¥128 / ¥88(苹果按 Tier 自动算)
- 日区:¥2,400 / ¥1,800
- 欧区:€18.99 / €12.99

具体 Tier 编号以 App Store Connect 实际配置为准。

## 免费 / 付费内容分界

### 深度解析(7 章 → 2 免费 + 5 付费)

**免费预览**(无 entitlement 也能看):
1. **性格底色** — 日主 + 五行倾向 + 整体格局倾向
2. **事业** — 职业方向 + 适合岗位类型

**付费章节**(需 entitlement):
3. **财运** — 正财/偏财倾向 + 富贵层级 + 流年财星触发
4. **爱情** — 婚姻方向 + 配偶特征 + 婚期窗口
5. **健康** — 体质倾向 + 注意部位 + 调候建议
6. **六亲** — 父母 / 兄弟 / 子女缘
7. **晚年** — 晚运倾向 + 中年转折点

### 合盘(待 Slice M4 细化)

跟深度解析同形态,**具体章节待合盘 prompt 模板拆分时定**。预期:
- **免费**:基础相处模式 + 互补/冲突总览
- **付费**:爱情深度 / 合作事业 / 财运合拍 / 流年同步

## Entitlement 数据模型

### 客户端 SwiftData

```swift
@Model final class Entitlement {
    @Attribute(.unique) var transactionId: String      // Apple JWS transactionId
    var productId: String       // "com.qicompass.deep_analysis.single" / ".compatibility.single"
    var contentHash: String     // 绑定到具体命盘(content_hash 或 compatibility_hash)
    var module: String          // "bazi_deep" / "compatibility"
    var userLocalId: String     // 客户端生成的 UUID(无账号系统的占位)
    var purchasedAt: Date       // 后端写入 entitlement 表的时间
    var originalPurchaseDate: Date  // Apple 返回的原始购买时间
    var isActive: Bool          // 退款/撤销后置 false
}
```

### 后端 SQLite

```sql
CREATE TABLE entitlement (
    transaction_id         TEXT PRIMARY KEY,    -- Apple JWS transactionId
    product_id             TEXT NOT NULL,
    content_hash           TEXT NOT NULL,       -- 绑定到命盘
    module                 TEXT NOT NULL,       -- "bazi_deep" / "compatibility"
    user_local_id          TEXT NOT NULL,       -- 客户端 UUID(v1 无账号)
    purchased_at           TEXT NOT NULL,       -- ISO 8601 UTC(后端写)
    original_purchase_date TEXT NOT NULL,       -- Apple 原始购买时间
    is_active              INTEGER NOT NULL DEFAULT 1,
    refunded_at            TEXT,                -- 退款 webhook 写入
    revoked_at             TEXT                 -- 家庭共享撤销写
);
CREATE INDEX idx_entitlement_lookup ON entitlement(content_hash, module, is_active);
CREATE INDEX idx_entitlement_user ON entitlement(user_local_id, is_active);
```

## 购买 + 校验流程

### iOS → 后端 Redeem

```
1. iOS StoreKit 2: Product.purchase()
2. Apple 完成交易,返回 VerificationResult<Transaction>(StoreKit 2 本地校验 JWS 签名)
3. iOS POST /api/entitlement/redeem
     {
       transaction_id: "...',
       product_id: "com.qicompass.deep_analysis.single",
       content_hash: "...",
       module: "bazi_deep",
       user_local_id: "<client UUID>"
     }
4. 后端调 Apple App Store Server API getTransactionInfo(transaction_id):
     - 验证 Apple JWT 签名有效(用苹果官方库)
     - 检查 productId 匹配请求
     - 检查 transaction 未被退款(statusField)
5. 后端 INSERT entitlement 表
6. 后端返回 { entitled: true, purchased_at, original_purchase_date }
7. iOS 调 Transaction.finish() 完成交易
8. iOS SwiftData 本地存 Entitlement 记录
```

### 后端付费接口拦截(`/api/interpret`)

新增 entitlement 中间件,**按 module + 章节范围**:

| 请求 | entitlement 要求 |
|---|---|
| `module=bazi_deep`,prompt=`bazi_deep_free` | **无要求**,返回免费 2 章 |
| `module=bazi_deep`,prompt=`bazi_deep_paid` | **要求 entitlement active**,返回付费 5 章 |
| `module=compatibility`,prompt=`compatibility_free` | **无要求**,返回免费章节 |
| `module=compatibility`,prompt=`compatibility_paid` | **要求 entitlement active**,返回付费章节 |

**实现关键**:
- 现在的 `bazi_deep` prompt 拆成 `bazi_deep_free`(2 章)+ `bazi_deep_paid`(5 章)
- 客户端调 `/api/interpret` 时传 `module=bazi_deep_free` 或 `bazi_deep_paid`,后端根据 module 检查 entitlement
- 缓存键 `(content_hash, module, ...)` 自动分开两份,不会污染

**越狱保护**:
- iOS 越 UI 绕过锁标 → 调 `/api/interpret bazi_deep_paid` → 后端检查 entitlement → 无 entitlement → 403
- 即使有人 reverse engineer iOS binary,也拿不到付费内容(prompt_hash + 后端 cache 拆分 + entitlement 三重保护)

### 退款 webhook

```
1. Apple App Store Server Notifications V2 → POST /api/webhooks/appstore
2. 后端解析 JWS,验证签名(用苹果官方库)
3. 通知类型:
   REFUND       → entitlement.is_active=0, refunded_at=now
   REVOKE       → entitlement.is_active=0, revoked_at=now
   (DID_RENEW / SUBSCRIBED 等订阅事件本场景不触发,消耗型)
4. 用户下次调付费接口会拿到 403(因为 is_active=0)
```

## 修改生辰触发重购

- `content_hash = sha256(birth_datetime, gender, city, zi_hour_rule, calc_rule_snapshot)`
- 改任何一个 → content_hash 变 → 新 entitlement 需要 → 重新购买
- **旧 entitlement 不失效**(用户还能看回旧命盘的付费内容)
- iOS UI:改生辰前弹确认 — "修改生辰需重新购买深度解析,旧命盘已购内容保留。确认修改?"

## 每日一问(新功能)

### Prompt 模板

```
你是一位精通中国传统四柱八字的导师。基于命主命盘信息和今日运势,
回答命主的具体问题。

命主:{gender},出生 {city},真太阳时 {true_solar_time}
四柱:{year_gan}{year_zhi} / {month_gan}{month_zhi} / {day_gan}{day_zhi} / {hour_gan}{hour_zhi}
今日运势(基于流日):{daily_fortune_summary}

用户问题:{user_question}

要求:
- 平实语言,不堆术语
- 给出具体可执行建议(时辰 / 方位 / 行为),不空泛
- 诚实告知不确定性,不假装预测 100% 准确
- 控制在 300 字以内
```

### 接口

`POST /api/daily_question`
```json
{
  "content_hash": "...",
  "user_question": "今天适合面试吗?",
  "target_date": "2026-07-18"
}
```

### 限制 + 历史

- **每天 1 次**(`user_local_id + target_date` 维度)
- 跟 `DailyReadCounter` 共用全局每日 10 次池(决策 §3.8)
- 历史存 SwiftData `DailyQuestion` model:
  ```swift
  @Model final class DailyQuestion {
      @Attribute(.unique) var id: UUID
      var contentHash: String
      var question: String
      var answer: String
      var targetDate: Date
      var createdAt: Date
  }
  ```

## 实施路径(分 Slice)

| Slice | 内容 | 工作量估 | 依赖 |
|---|---|---|---|
| **M1** | 本 doc 用户 review 通过 | - | - |
| **M2** | 后端:entitlement 表 + `/api/entitlement/redeem` + App Store Server API 集成 + 退款 webhook + prompt 拆分(`bazi_deep_free` / `_paid`) | 大 | M1 |
| **M3** | iOS:StoreKit 2 + PurchaseManager + 购买 UI + 锁标 + 付费章节展开 UI + Entitlement SwiftData model | 中 | M2 |
| **M4** | 合盘付费(M2/M3 复制粘贴 + 价格档 + 合盘 prompt 拆分) | 中 | M3 |
| **M5** | 每日一问(后端 prompt + 接口 + 限制 + iOS UI + 历史) | 中 | - |
| **M6** | App Store Connect 配置两个 Consumable + TestFlight 沙盒账号验证购买/退款流程 | 小 | M2-M4 |

### 新依赖待用户同意

按 `~/.claude/CLAUDE.md` "不擅自加依赖"原则,以下新依赖在 M2/M5 实施前需用户单独确认:

| 依赖 | 引入理由 | 替代方案 | 不引入的代价 |
|---|---|---|---|
| **Python: `app-store-server-library`** | 苹果官方 SDK,封装 App Store Server API 的 JWT 签名 + JWS 验证 + transaction 查询 | 自己用 `httpx` + `cryptography` 手写 JWT 签名 + ECDSA P-256 验证(数百行) | 手写 crypto 错误风险高,且苹果升级 API 时要自己跟 |
| **iOS: StoreKit 2** | 苹果系统自带,Swift 原生 API | — | 不引入 = 不能做 IAP |
| **iOS: SwiftData** | 项目已用,无新依赖 | — | — |

## 不做(v1 范围外,延后到 v2)

- **订阅制**(月 / 年 / 终身买断)— v1 只做消耗型
- **家庭共享** — 苹果自动支持家庭共享消耗型 IAP,但 v1 不主动配置(`IS_FAMILY_SHAREABLE = false`)
- **跨设备 entitlement 同步** — v1 无账号系统,entitlement 只在本机 + 后端;换机/重装后无法证明"是自己"(v2 加账号后通过 `appAccountToken` 关联)
- **优惠码 / 推广活动** — v2
- **礼物卡 / 赠送** — v2
- **苹果促销代码** — v1 不主动发(App Store Connect 默认支持)
- **企业批量授权** — v2 B2B

## 风险 + 取舍

| 风险 | 缓解 |
|---|---|
| App Store Server API 集成复杂(签名/JWT/证书) | 用苹果官方 `app-store-server-library`,签名封装好;M2 实施时另立 spike |
| $18 单价高 → 转化率低 | 免费章节质量必须够好(性格底色 + 事业是"硬菜"不是"前菜"),让用户"看完想买"。监控转化率,必要时调整免费/付费分界 |
| 越狱破解(即使后端校验也有路径,例如有人共享 transactionId) | v1 用户量小,风险低;后端可加 transactionId → user_local_id 绑定校验(同一 transactionId 不能换 user) |
| 用户改生辰后失去付费内容不爽 | UI 明示 + 确认弹窗 + 旧 entitlement 不失效(还能看回旧命盘付费内容) |
| 苹果抽成 30% | $18 → 苹果 $5.4,你拿 $12.6;小开发者 < $1M/年营收抽成 15%(苹果 Small Business Program),前期能省一半 |
| 中国大陆 App Store 命理类审核严格 | 文案避免"算命 / 预测绝对",用"倾向 / 参考 / 命局呈现";加"玄学娱乐,理性参考"免责声明 |
| 苹果 Price Tier 自动换算的 ¥128 在中国偏高 | 接受,跟"高端定位"一致;若转化率低,后续单独配 China region 价格档(苹果允许逐市场覆盖) |

## Open Questions(后续 review 可能调整)

- **免费试用期?** 目前不需要(免费章节已经是常驻免费,等于"永久试用 2 章")
- **邀请好友送 1 次深度解析?** v2 推广功能,需要后端 referral 表 + 苹果 Promotion Codes 配合
- **深度解析包月不限次?** 跟"消耗型 IAP per-命盘"冲突,不做。如果用户反馈强烈,v2 加订阅
- **跨模块打包**(深度解析 + 合盘 bundle)? v2,需要新 product_id
- **订阅用户专享高级功能**(如流年同步全年)? v2

## 验收标准(M6 TestFlight 完成)

- [ ] 沙盒账号能完成深度解析购买流程(SKpayment → redeem → entitlement 入表 → 付费章节解锁)
- [ ] 沙盒账号能完成合盘购买流程
- [ ] 修改生辰 → content_hash 变 → 付费章节重新锁住,需重新购买
- [ ] 沙盒模拟退款 → 后端 webhook 收到 → entitlement `is_active=0` → 付费章节 403
- [ ] 越狱设备(或调试模式跳过 StoreKit)直接调 `/api/interpret bazi_deep_paid` → 403
- [ ] 每日一问:第 1 次成功,第 2 次当天返回 429 `DAILY_LIMIT_REACHED`
- [ ] 每日一问历史 SwiftData 持久化,跨启动能回看
- [ ] App Store Connect 两个 product 配置正确,在 TestFlight build 上可见可购
