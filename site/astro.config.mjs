import { defineConfig } from 'astro/config';
import { SITE } from './src/data/site';

// knowfate.app — 静态输出;URL 无尾斜杠(规格 README §3)。
// 根路径 / → /en 302 由 public/_redirects(Cloudflare Pages)处理,不用 JS 跳转。
// 注:不用 Astro 内建 i18n 路由配置——static 模式下它只提供与 _redirects 重复的
// 根重定向并强制要求根 index 页;语言路由由 src/data/site.ts 的 stripLang/langPath 手动承担。
// format 必须用 'file'(规格明文二选一):'directory' 在 Cloudflare Pages 上会把 /en
// 308 到 /en/(目录资产规范化),与 _redirects 的 /en/ /en 308 互为死循环
// (wrangler pages dev 实测);'file' 产出 en.html / en/kitchen-sink.html,
// 无斜杠 URL 直接 200,无斜杠变体由 _redirects 归一,Astro 文档推荐 pairing 也是
// file ↔ trailingSlash:'never'。
export default defineConfig({
  // 域名单一事实源 = src/data/site.ts 的 SITE.domain(canonical/og 也从那取),config 这里只消费
  site: SITE.domain,
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'file' },
});
