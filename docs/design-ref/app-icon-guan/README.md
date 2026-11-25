# 观命 App 图标出稿(改名 S02)

- `board.html`:对比板,浏览器直接打开(引用 App 打包字体与现有图标,需在仓库内打开)
- `icon.html` + `render.js`:渲染模板与生成脚本。重新生成:`node docs/design-ref/app-icon-guan/render.js`(依赖环境预装的 Playwright,无新依赖)
- `png/`:6 张候选,1024×1024 不透明 RGB PNG。`A` 同构 / `B` 朱印 / `C` 墨圆;`sc` 简体「观」/ `tc` 繁体「觀」

配色沿用现有「玄」图标实测取色:米色底 `#F5EFE1`、朱红 `#C33B3B`。

## 选稿记录

- **2026-11-25 用户选定:A 同构 · 简体「观」**(`png/A-sc.png`),已替换 `ios/.../AppIcon.appiconset/AppIcon-1024.png`(1024×1024,RGB 无 alpha,与 `png/A-sc.png` 逐字节相同)
- 理由:与原「玄」图标同构,只换字,老测试用户一眼认得;「观」6 画,主屏 60px 与设置页 40px 都清楚;繁体「觀」25 画小尺寸发糊,且图标不能按语言切换
- 旧图标存档:`png/OLD-xuan.png`(对比板「现有 · 玄」一栏引用它)
