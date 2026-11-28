// S06:构建后扫 site/dist 生成 sitemap-index.xml + 按页面类型分片的
// sitemap-<type>.xml(规格 README §6)。
//
// 为什么不用 @astrojs/sitemap:它只按页数均分 shard,给不出
// sitemap-day-master.xml 这类「类型名 shard」;自己扫产物反而更简单——
// canonical / hreflang / noindex / lastmod 全部读页面产物,单一事实源。
//
// 规则:
// - 排除:robots meta 含 noindex 的页(kitchen-sink / 草稿)、dist/404.html
// - 分片:语言前缀后的首段 = 内容集合(day-master / ten-gods / …)各自成
//   shard;首段的浅页(about / privacy / bazi-calculator …)统一进 pages;
//   首页(rest 为空)进 home
// - 每条 <url> 带 xhtml:link hreflang(en / zh-Hant / x-default)互指;
//   lastmod 取 article:modified_time(文章页有,工具页省略)
// - 错误显式传播:缺 canonical / 缺 hreflang / canonical 与页面自身 URL
//   不一致 → 直接抛错终止构建,不静默产出坏 sitemap
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const siteRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(siteRoot, "dist");
const domain = "https://knowfate.app";

/** 多页内容集合:首段即 shard 名(二期逐个上线,S06 先登记前缀规则) */
const COLLECTION_SEGMENTS = new Set([
  "day-master", "ten-gods", "five-elements", "stars", "guides",
  "glossary", "day-pillar", "compatibility", "zodiac", "today",
]);

if (!existsSync(dist)) {
  throw new Error(`dist 不存在:${dist}——本脚本须在 astro build 之后运行`);
}

/** 递归收 dist 下的 .html(跳过 dist 根的 404.html:自包含,无 canonical) */
function htmlFiles() {
  const out = [];
  (function walk(dir) {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) walk(p);
      else if (name.endsWith(".html") && p !== join(dist, "404.html")) out.push(p);
    }
  })(dist);
  return out;
}

/** dist 文件 → 站点路径:dist/en.html → /en;dist/en/library.html → /en/library */
function siteUrlOf(file) {
  return "/" + relative(dist, file).replace(/\.html$/, "");
}

/** 按站点**路径**(/en/…,非绝对 URL)定 shard:首段为空 = 首页 */
function shardOfType(path) {
  const m = path.match(/^\/(?:en|zh-hant)(?:\/([^/]+))?/);
  const seg = m?.[1];
  if (!seg) return "home";
  return COLLECTION_SEGMENTS.has(seg) ? seg : "pages";
}

const pages = [];
for (const file of htmlFiles()) {
  const html = readFileSync(file, "utf8");
  const robots = html.match(/<meta name="robots" content="([^"]*)"/);
  if (robots && robots[1].includes("noindex")) continue;
  const canonical = html.match(/<link rel="canonical" href="([^"]*)"/)?.[1];
  if (!canonical) {
    throw new Error(`${relative(siteRoot, file)} 无 canonical——BaseHead 没跑或被绕过`);
  }
  const path = siteUrlOf(file);
  const self = domain + path;
  if (canonical !== self) {
    throw new Error(
      `${relative(siteRoot, file)} canonical(${canonical})与自身 URL(${self})不一致`
    );
  }
  const alternates = [...html.matchAll(/<link rel="alternate" hreflang="([^"]*)" href="([^"]*)"/g)]
    .map((m) => ({ hreflang: m[1], href: m[2] }));
  const langs = alternates.map((a) => a.hreflang).sort();
  if (langs.join(",") !== "en,x-default,zh-Hant") {
    throw new Error(
      `${relative(siteRoot, file)} hreflang 集不全:${langs.join(",") || "(无)"}(期望 en/zh-Hant/x-default)`
    );
  }
  const lastmod = html.match(/<meta property="article:modified_time" content="([^"]*)"/)?.[1];
  pages.push({ url: self, alternates, lastmod, shard: shardOfType(path) });
}

pages.sort((a, b) => a.url.localeCompare(b.url));
if (pages.length === 0) throw new Error("dist 中没有任何可收录页——sitemap 无从生成");

const shardNames = [...new Set(pages.map((p) => p.shard))].sort();

function xmlEscape(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

for (const shard of shardNames) {
  const entries = pages.filter((p) => p.shard === shard);
  const body = entries.map((p) => {
    const alts = p.alternates
      .map((a) => `    <xhtml:link rel="alternate" hreflang="${xmlEscape(a.hreflang)}" href="${xmlEscape(a.href)}"/>`)
      .join("\n");
    const lastmod = p.lastmod ? `\n    <lastmod>${p.lastmod.slice(0, 10)}</lastmod>` : "";
    return `  <url>\n    <loc>${xmlEscape(p.url)}</loc>${lastmod}\n${alts}\n  </url>`;
  }).join("\n");
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${body}
</urlset>
`;
  writeFileSync(join(dist, `sitemap-${shard}.xml`), xml);
}

const indexXml = `<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${shardNames.map((s) => `  <sitemap>\n    <loc>${domain}/sitemap-${s}.xml</loc>\n  </sitemap>`).join("\n")}
</sitemapindex>
`;
writeFileSync(join(dist, "sitemap-index.xml"), indexXml);

const counts = shardNames.map((s) => `${s}=${pages.filter((p) => p.shard === s).length}`).join(" ");
console.log(`gen-sitemap: ${pages.length} 页 / ${shardNames.length} shard(${counts})`);
