# App 改名 KnowFate · 知命 — 设计决策(2026-11-24)

Status: 拍板 3 项(下表);**S01 名称与商标核查是前置关卡,未通过前不动代码**
关联:`docs/SEO站设计决策.md` 11-24 增补(网站先行改名 KnowFate)/ `docs/appstore-metadata.md` / `DESIGN.md`(品牌指纹)/ `docs/官网实现-slices/`
实施分割:`docs/App改名-slices/`

## 拍板结论

| # | 决策点 | 拍板 | 要点 |
|---|---|---|---|
| 1 | 中文名 | **「知命」**(替换「玄机问道」) | 与 KnowFate 意义对应(Know = 知,Fate = 命);典出《论语·为政》「五十而知天命」 |
| 2 | 图标与品牌印 | **「知」**(替换「玄」) | 单字朱印。功能印「解」「合」「批」不变 |
| 3 | 内部标识 | **全部不改** | 只改用户看得见的地方,理由见下 |

### 决策 3 的范围:不改的内部标识

| 标识 | 现值 | 不改的理由 |
|---|---|---|
| Bundle ID | `com.qicompass.app`(tests `.tests`) | App Store Connect 记录建立后永久不可改;用户不可见 |
| 内购商品 ID | `com.qicompass.deep_analysis.single` / `.compatibility.single` / `.daily_ask.pack15` | 创建后不可改名、删除后不可复用;双端映射有 `check_sku_sync.py` 守护,动它=资损风险 |
| App Group | `group.com.qicompass.app` | 改了会让已装 TestFlight 用户的本地命盘丢失(TASK-05 迁移刚做完) |
| 苹果登录 Client ID | `com.qicompass.app` | 与 Bundle ID 绑定 |
| 后端环境变量 / DB | `QICOMPASS_*`、`data/qicompass.db`、表 `qicompass_user`、JWT `iss` | 纯内部;改了要迁库、改部署配置 |
| HTTP 头 | `X-QiCompass-Lang` | App 与后端的内部协议 |
| 工程 / 模块 / 目录名 | Xcode target `QiCompass`、仓库名、`QiCompassApp.swift` | 动 pbxproj 与上百文件,回归风险大、用户无感 |
| 字体文件名 | `QiSongti*.otf` | 内部资源名 |

## 改名的全部落点(用户可见)

| 位置 | 现在 | 改为 | Slice |
|---|---|---|---|
| 主屏幕 App 名(CFBundleDisplayName) | QiCompass | 简繁中文系统「知命」/ 英文系统「KnowFate」(默认取舍,见下) | S03 |
| App 图标 | 朱红「玄」 | 朱红「知」 | S02 |
| 启动页 | 「玄」印 + 竖排「玄机问道」+ 副题「问道于心 · 观命如水」+ QICOMPASS | 「知」印 + 竖排「知命」+ 新副题(S03 候选)+ KNOWFATE | S03 |
| 引导页 | 「玄」印 +「玄机问道」+ QICOMPASS + 无障碍标签「玄机问道印章」 | 「知」印 +「知命」+ KNOWFATE +「知命印章」 | S03 |
| 深度解析主页喜忌行 | 「玄」印 | 「知」印 | S03 |
| 「我的」页底部 | QICOMPASS +「玄机问道 · 专业不忽悠」 | KNOWFATE +「知命 · 专业不忽悠」 | S03 |
| 切换语言后的重启提示(2 条) | 「请从后台上滑关闭 QiCompass…」 | 跟随主屏幕名:中文「知命」/ 英文「KnowFate」 | S03 |
| App Store 名称 / 副标题 / 描述 / 关键词 / 截图文案 | QiCompass 八字命书 等 | 见 S04 | S04 |
| 隐私政策 / 用户协议 / 技术支持 | 玄机问道(QiCompass)、support@qicompass.app(待定) | KnowFate · 知命、`hello@knowfate.app`、`https://knowfate.app/en/privacy` | S04 |
| 苹果登录授权弹窗显示的 App 名 | 取自 App Store Connect 的 App 名 | 随 S04 自动变化 | S04 |
| 官网 | 已是 KnowFate,印章仍是「玄」 | 印章「知」,繁中站品牌「知命」 | S05 |
| 设计系统与项目文档 | DESIGN.md 品牌印「玄」、QICOMPASS 字距标 | 同步 | S05 |

## 默认取舍(未单独拍板,按惯例定;有异议再改)

- **主屏幕名按系统语言区分**:简 / 繁中文系统显示「知命」,英文系统显示「KnowFate」。主屏幕名必须与 App Store 名称相近(审核 2.3.7 / 2.3.8),所以商店名称同时包含两者(见 S04)
- **英文界面不翻译「知命」**:与现有「印章 / 品牌字保持中文不翻译」口径一致(DESIGN.md 2026-08-26 决策 7);英文界面品牌位显示 KNOWFATE 字距标,印章仍为「知」
- **改名时机**:在**首次提交 App Store 审核之前**完成。上架前改名零成本(无评论、无排名、无老用户认知);上架后改名会丢失品牌搜索积累
- **TestFlight 测试者**:下一次送测时在「测试内容」里说明改名,不单独通知

## 风险

1. **「知命」可能与现有产品撞名**:`DESIGN.md` 第 11 行把「知命」列为国内对标产品。2026-11-24 网页搜索 App Store 没找到同名 App,但无法确认是否已下架、是否注册了商标。→ **S01 必须核查**;撞名时的备选见 S01
2. **「KnowFate」在 App Store 的可用性未知**:App Store 名称全局唯一,只能在 App Store Connect 里实际填写时才知道是否被占用 → S01
3. **英文名与中文名语义一致但不是音译**:英文用户不会知道「知命」怎么读。这是有意为之(中文名服务中文用户),不作为问题处理

## 不做

改 Bundle ID / 内购 ID / App Group / 环境变量 / 数据库 / 工程名(决策 3);重新设计整套视觉(只换品牌字与图标字,水墨孤本不变);改仓库名。
