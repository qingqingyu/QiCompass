# TestFlight 种子用户邀请 + 反馈收集

5 个种子用户(外部测试组)邀请流程、邮件模板、反馈渠道与 SLA。

> 前置条件:已完成 [`archive-testflight.md`](./archive-testflight.md) 的上传流程,TestFlight 至少有一个 Available build。

---

## 1. 创建外部测试组

App Store Connect → App → **TestFlight** → **外部测试组**(左侧,与"内部测试组"区分)→ 点 **+** 新建组:

- **组名**:`Seed Beta`
- **添加 tester**:5 个 email,逐个输入
- Apple 自动发邀请邮件(发件人 `no-reply@email.apple.com`),tester 收到后点链接接受

> 不选内部测试组的原因:内部 tester 必须是 Apple Developer Team 成员(占席位 / 权限风险 / 个人 Developer 账号无法加入)。外部 tester 只需 email,代价是首次 build 需 beta review(~1 天)。

### 公开邀请链接(备选)

外部测试组详情页 → **启用公开链接** → 得到一个 `https://testflight.apple.com/join/XXXX` 链接。任何有此链接的人可直接安装,不必逐个加 email。适合:
- 不想暴露 tester email 给 Apple
- 临时分享给更多人

风险:链接泄露则任何人可装,**不要公开发布**;不用时禁用。

---

## 2. 邀请邮件模板

以下模板用邮件客户端发给 5 个种子用户。`{{}}` 占位符发送前替换。

---

**主题**:`QiCompass 内测邀请 · 反馈截止 {{反馈截止日,如 2026-07-27}}`

**正文**:

```
你好,

我是 {{你的名字}}。最近在做一个 iOS App 叫 QiCompass(玄机问道),
AI 八字命理工具,有三个模块:深度解析(看个人命盘)、合盘(看两人匹配)、
每日运势(每天一张运势卡)。

因为你是我信任的朋友 / 同行,想邀请你做种子用户,提前体验并给我反馈。

【怎么装】
1. Apple 会单独发一封 TestFlight 邀请邮件(发件人 no-reply@email.apple.com),
   找那封邮件,点里面的"View in TestFlight"或"开始测试"按钮。
   没收到的话先查垃圾箱,或用这个公开链接直接装:{{TestFlight 公开邀请链接}}
2. 装 Apple 官方的 TestFlight app(App Store 搜 TestFlight)
3. 在 TestFlight 里装 QiCompass
4. 装完后桌面会出现 QiCompass 图标,打开即可

【预期管理】
- 这是 alpha 版,bug 必然存在,闪退 / 算错 / 文案不通都可能发生
- 你的命盘数据只存在你手机本地,不上云,我不会看到(隐私放心)
- 排盘(八字四柱)用的是开源库 lunar_python,准确性有 200+ 测试用例背书,
  但 LLM 生成的"命书"是 AI 润色文案,别当真

【重点测什么】
- 三模块都过一遍:深度解析 → 合盘 → 每日运势
- 排盘准确性:如果你懂八字,对照你自己的盘看四柱 / 大运对不对
- 卡顿 / 闪退 / 错别字 / 不通顺的文案

【怎么给我反馈】(优先级排序)
1. 【首选】TestFlight 内置反馈:App 里摇一摇,或截图后点右上角分享 →
   "Send Feedback",自动带截图 + build 号 + 设备信息,直达我的 App Store Connect
2. 【次选】邮件 / 微信:{{你的联系方式}}
3. 【可选】结构化反馈表:{{Google Form / 腾讯问卷链接,若准备了}}

反馈请尽量包含(方便我复现):
- 设备型号(如 iPhone 15 Pro / iPhone 13 mini)
- iOS 版本(设置 → 通用 → 关于本机 → 软件版本)
- 操作路径(从哪个 Tab → 点了什么 → 触发了什么)
- 截图 / 录屏(必备)
- 期望结果 vs 实际结果

【时间】
- 反馈截止日:{{2026-07-27}}
- 不必一次性测完,想起来就测,累计反馈即可

【SLA】
我单人开发,不承诺实时回复。反馈我会在 48 小时内 ack,1 周内集中回复 + 出修复 build。

谢谢你!

{{你的名字}}
```

---

## 3. 反馈渠道说明

### 主推:TestFlight 内置反馈

tester 操作:
1. 在 QiCompass 里**摇一摇**,或**截图**(同时按侧边按钮 + 音量+),截图预览出现后点右上角分享图标
2. 选 **"Send Feedback with TestFlight"**
3. 填文字描述 → 发送

**自动带上**:
- 当前 build 号
- 设备型号 + iOS 版本
- 截图(若从截图分享入口进)
- App 诊断日志

直达 App Store Connect → TestFlight → Feedback,**首选**。

### 次选:邮件 / 微信

给一个专用地址(如 `qicompass-feedback@{{你的域名}}` 或微信)。代价:tester 要手动描述设备 / build / 操作路径,信息密度低。

### 可选:结构化反馈表

Google Form / 腾讯问卷,字段:
- 严重程度(1-5)
- 模块(深度解析 / 合盘 / 每日运势 / 排盘 / 其他)
- 设备型号 / iOS 版本(下拉)
- 复现步骤(文本)
- 截图上传

适合收集周期性总结,但临时性 bug 仍走 TestFlight 内置反馈更快。

---

## 4. 建议反馈格式(写进邮件模板和 TestFlight 反馈说明)

为了让反馈可复现,引导 tester 给出以下结构(不需要严格,作为参考):

```
【设备】iPhone 15 Pro / iOS 17.5
【build】TestFlight 里 QiCompass → build 号(如 12)
【模块】每日运势
【操作路径】打开 App → 底部 Tab "每日" → 等了 10 秒
【期望】显示今日运势卡 + 12 时辰
【实际】一直转圈,最后报错"网络超时"
【截图】(附)
【其他】家里 WiFi 正常,其他 App 能上网
```

---

## 5. SLA

**单人开发,不承诺实时**。具体:

- **48 小时内 ack**:确认收到反馈,简短回复"收到,排查中"
- **1 周内集中回复**:批量处理,出修复 build 后通知相关 tester
- 紧急 crash(data loss / 闪退)优先于文案问题
- 文案 / 文字润色问题积攒到一定数量后批量改

邮件模板里 SLA 段落已写明,避免 tester 期待实时响应。

---

## 6. tester 名单管理(单人 dev 极简版)

不引入外部工具,用一个本地表格(Numbers / Excel / Notion)记录:

| email | 邀请日 | 是否接受 | 最后一次反馈日 | 反馈数 | 备注 |
|---|---|---|---|---|---|
| ... | ... | ✓ / ✗ | ... | ... | ... |

5 个 tester 手动维护即可。超过 10 人再考虑工具。
