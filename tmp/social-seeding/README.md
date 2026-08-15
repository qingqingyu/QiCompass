# 社媒传播种草素材(草稿 v0.1)

> 位置:`tmp/social-seeding/`(gitignore,不进 git)
> 战略依据:2026-08-12 i18n grill 拍板——真正 40 倍杠杆是**内容营销 + 差异化**,不是堆语言。
> 配套工具:promo-site(`tmp/promo-site/`)负责生成真实解读截图(1080px 带水印,发帖直接用)。

## 文件索引

| 文件 | 平台 | 状态 |
|---|---|---|
| `reddit-en.md` | Reddit(r/bazi、r/ChineseAstrology 等,英文) | 草稿 v0.1 |
| `xiaohongshu.md` | 小红书(中文主阵地) | 草稿 v0.1 |
| `douyin-weibo.md` | 抖音/微博(次优先级) | 草稿 v0.1 |
| `copy-bank.md` | 跨平台话术库(钩子/评论应答/质疑应对) | 草稿 v0.1 |

## 总策略(三句话)

1. **打「不忽悠」的差异化**:全网命理内容都在讲吉凶祸福,我们讲结构、依据、自我认知——评论区天然有辨识度。
2. **Reddit 先行**:英文社区对 bazi 有真实兴趣且反感 spam,「engineer-built bazi app」人设契合;promo-site 截图工具就是为此造的。
3. **小红书做中文主阵地**:「自我认知/东亚小孩认清自己」是流量母题,八字是切入角度,产品是答案。

## 发布节奏建议

| 周 | 动作 |
|---|---|
| W1 | Reddit 2 帖(工具分享型,非广告型)+ 小红书 3 篇(自我认知角度) |
| W2 | 看数据:哪种 hook 互动好 → 加倍;差的停 |
| W3+ | 固定栏目化(如「每周一个十神结构」),养期待感 |

## 红线(全平台)

- 不承诺「准」、不晒「灵验」截图钓鱼
- 不用「转运/改命/化解」话术(同 App Store 合规口径,见 `../app-store-launch/review-compliance.md`)
- Reddit 严打 self-promo:每帖必须 90% 价值内容 + 10% 产品提及,首帖不发链接
- 所有截图过 promo-site 禁词校验(forbidden_words)再发
