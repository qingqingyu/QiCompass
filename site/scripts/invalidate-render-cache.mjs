// content-layer 渲染缓存失效(S02 #4 配套)。npm run build 的 prebuild 钩子。
//
// 为什么需要:Astro 5 content layer 把条目渲染结果缓存在 node_modules/.astro/
// (data-store.json),失效判据只有**内容文件 digest**(generateDigest(contents))。
// 渲染输出还依赖另一组输入——remark 插件源码、terms.json(自动内链数据)、
// term-defs.json(释义卡)、astro.config.mjs(markdown 管线装配)——这些变更
// **不会**触发重渲染,build 全绿但 dist 静默复用旧 HTML(2026-11-25 实测:
// 改插件一行,重建后 dist 不含改动)。
//
// 做法:对上述渲染依赖逐文件取 SHA-256 指纹,与 node_modules/.astro/.render-deps.json
// 对比;不一致(或指纹缺失)→ 删整个 node_modules/.astro(Astro 下次 build 自建),
// 写新指纹。删除原因显式打印,不静默。
//
// 无第三方依赖(node:crypto/fs);失效为幂等操作,重复 build 不再删。
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

function listPluginFiles() {
  // withFileTypes 过滤:目录名碰巧以 .mjs 结尾时 readFileSync 会 EISDIR 炸掉 build
  return readdirSync(SITE_ROOT + "src/plugins", { withFileTypes: true })
    .filter((e) => e.isFile() && (e.name.endsWith(".mjs") || e.name.endsWith(".js")))
    .map((e) => e.name)
    .sort();
}

const SITE_ROOT = fileURLToPath(new URL("..", import.meta.url));
const STORE_DIR = fileURLToPath(new URL("../node_modules/.astro/", import.meta.url));
const DEPS_FILE = STORE_DIR + ".render-deps.json";

// 渲染输出的全部输入(除内容文件本身):config 装配管线,plugins 决定链接,两个
// data 文件喂插件。glob 按目录展开,新增插件文件无需登记。
const RENDER_DEPS = [
  "astro.config.mjs",
  "src/data/terms.json",
  "src/data/term-defs.json",
  ...listPluginFiles().map((f) => `src/plugins/${f}`),
];

function fingerprint() {
  const fp = {};
  for (const rel of RENDER_DEPS) {
    const abs = SITE_ROOT + rel;
    if (!existsSync(abs)) {
      fp[rel] = "missing";
      continue;
    }
    fp[rel] = createHash("sha256").update(readFileSync(abs)).digest("hex");
  }
  return fp;
}

const current = JSON.stringify(fingerprint(), null, 2);
const stored = existsSync(DEPS_FILE) ? readFileSync(DEPS_FILE, "utf-8") : null;

if (stored === current) {
  console.log("[prebuild] 渲染依赖未变,content-layer 缓存保留");
} else {
  const reason = stored === null ? "无指纹记录(首次或缓存已清)" : "渲染依赖有变更";
  rmSync(STORE_DIR, { recursive: true, force: true });
  mkdirSync(STORE_DIR, { recursive: true });
  writeFileSync(DEPS_FILE, current, "utf-8");
  console.log(`[prebuild] ${reason},已失效 content-layer 渲染缓存(node_modules/.astro)`);
}
