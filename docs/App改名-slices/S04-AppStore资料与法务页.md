# S04 App Store 资料与法务页

- **类型**: AFK(起草)+ HITL(用户在 App Store Connect 填写与提交)
- **Blocked by**: S01(名称可用)、S02(截图需新图标)
- **Parent**: `docs/App改名KnowFate设计决策.md`;现行元数据 `docs/appstore-metadata.md`(10-28 拍板,措辞红线沿用)

## What to build

1. **改写 `docs/appstore-metadata.md` 三语版本**(保留原红线与字数标注):

   | 语言 | 名称(≤30) | 副标题(≤30) |
   |---|---|---|
   | zh-Hans | 观命 KnowFate · 八字命书 | 专业排盘 · 深度命书 · 今日宜忌(不变) |
   | zh-Hant | 觀命 KnowFate · 八字命書 | 專業排盤 · 深度命書 · 今日宜忌(不变) |
   | en | **KnowFate - Chinese Astrology**(28,用户指定,决策 4) | Your chart, read like a book(28,沿用) |

   - 名称以 S01 实测能保存的为准;字数逐个复核
   - 关键词:**不得重复名称里已有的词**(App Store 规则),原关键词里如有「观命」「KnowFate」相关词要删;腾出的字数补长尾词
   - **en 关键词必改**:现有 `four pillars,chinese astrology,compatibility,daily horoscope,wuxing,heavenly stems,daily fortune` 里的 `chinese astrology` 与新名称重复,要删;新名称不含 Bazi,而 bazi 是本品类核心搜索词,**必须补进关键词**(例如 `bazi,four pillars,compatibility,daily horoscope,wuxing,heavenly stems,day master,ten gods`,以 ≤100 字符实测为准)
   - 描述首句「QiCompass 是一本认真排盘的八字命书」→「观命(KnowFate)是一本……」(繁体「觀命」);en 同理
   - 截图标题(6 张)里如有品牌名同步替换
   - 版权:`2026 KnowFate`
2. **隐私政策 / 用户协议**:`tmp/app-store-launch/privacy-policy.md` 等草稿中「玄机问道(QiCompass)」→「观命(KnowFate)」(繁体「觀命」);联系邮箱 `hello@knowfate.app`;隐私政策网址 `https://knowfate.app/en/privacy`(与官网 S05 同一份正文,避免两处不一致);技术支持网址 `https://knowfate.app/en/about` 或单独支持页
   - `tmp/` 是 gitignore 目录:若本机没有这些草稿,向用户索取,不要自行编写法律条款
3. **App Store Connect 填写清单**(给用户照着点):App 信息 → 名称 / 副标题(三语)、隐私政策网址、版权;版本信息 → 描述 / 关键词 / 宣传文本 / 支持网址 / 截图;内购商品的**显示名称**里若含品牌名也一并改(**商品 ID 不改**)
4. **苹果登录**:授权弹窗显示的是 App Store Connect 里的 App 名称,无需代码改动;S06 走查时确认

## Acceptance criteria

- [ ] `docs/appstore-metadata.md` 三语全部更新,每个字段标注字数且不超限
- [ ] 关键词与名称无重复词(逐条列出核对结果)
- [ ] 全文无「算命 / 预测 / 准确 / 改运」
- [ ] 隐私政策只有一个事实源(官网页),App Store 填该网址
- [ ] 用户在 App Store Connect 完成填写(截图回报)
