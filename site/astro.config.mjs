import { defineConfig } from 'astro/config';

// knowfate.app — 静态输出;URL 无尾斜杠(规格 README §3)。
// 根路径 / → /en 302 由 public/_redirects(Cloudflare Pages)处理,不用 JS 跳转。
// 注:不用 Astro 内建 i18n 路由配置——static 模式下它只提供与 _redirects 重复的
// 根重定向并强制要求根 index 页;语言路由由 src/data/site.ts 的 stripLang/langPath 手动承担。
export default defineConfig({
  site: 'https://knowfate.app',
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'directory' },
});
