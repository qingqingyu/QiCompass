# App Store 上架素材（QiCompass · 玄机问道）

> 位置:`tmp/app-store-launch/`(gitignore,不进 git)
> 用途:App Store Connect 上架所需的全部文案与素材的**草稿工作区**。所有文案都是 v0.1 草稿,定稿前需用户逐条拍板。
> 事实源:产品定位见 `STRATEGIC_DIFF.md` + `bazi-app-design-doc.md`;视觉见 `DESIGN.md`;付费见 `MONETIZATION.md`。

## 文件索引

| 文件 | 内容 | 状态 |
|---|---|---|
| `listing-zh.md` | 商店元数据:名称/副标题/关键词/推广文本/描述/新功能 | 草稿 v0.1 |
| `review-compliance.md` | 审核合规要点(命理类话术边界/隐私/IAP) | 草稿 v0.1 |
| `screenshots-plan.md` | 截图与预览视频规划 | 草稿 v0.1 |

## 上架流程清单(中国区优先,美区随后)

- [ ] 1. 定稿 `listing-zh.md` 全部文案(用户拍板)
- [ ] 2. Apple Developer 账号确认 + App Store Connect 建 App(_bundle id / SKU_)
- [ ] 3. 截图制作(按 `screenshots-plan.md`,可用 promo-site 生成内容 + 模拟器截图)
- [ ] 4. 隐私政策页面 URL(内容要点见 `review-compliance.md` §隐私)
- [ ] 5. 技术支持 URL(最简:一个邮箱或 GitHub Issues 页)
- [ ] 6. IAP 商品配置:深度解析 $17.99 / 合盘 $11.99(消耗型,MONETIZATION.md 口径)
- [ ] 7. 年龄分级问卷(按 `review-compliance.md` §年龄分级作答)
- [ ] 8. TestFlight 内测(已有 M6 流程)→ 提交审核
- [ ] 9. 美区/英文 listing(等 i18n 计划落地,repo 根 `i18n-implementation-plan.md`)

## 硬性字数上限(App Store Connect,中文区)

| 字段 | 上限 |
|---|---|
| App 名称 | 30 字符 |
| 副标题 | 30 字符 |
| 关键词 | 100 字符 |
| 推广文本 | 170 字符 |
| 描述 | 4000 字符 |
| 新功能(What's New) | 4000 字符 |
