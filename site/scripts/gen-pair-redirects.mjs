// S06:合盘(二期)成对页 URL 归一——`b-and-a` 形式 301 到天干顺序的
// `a-and-b`(规格 README §6)。一期没有 compatibility 页,本脚本空跑;
// 二期页面一上线即自动生效,不占依赖。
//
// 规则产出(2026-11-28 review 修正,Codex P1):每个「正序页」(a-and-b)
// 都要产出它的反序别名规则(b-and-a → a-and-b),不依赖反序文件真的存在
// ——只有反序文件存在才出规则 = 用户访问 b-and-a 时无规则、直接 404。
// 反序文件若也存在,则同样归一到正序页(两路规则经 Set 去重)。
//
// 天干顺序与术语 slug 均取既有单一事实源(STEM_ORDER / terms.json),
// 本脚本不自带第二份天干表。属同一对干(x-and-x)或 slug 解析不出
// 天干 → 直接抛错;天干不在 STEM_ORDER 里也抛错(排 -1 会静默产生
// 错误排序,2026-11-28 review A7)。
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { STEM_ORDER } from "../src/lib/daymaster.mjs";

const siteRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

// --dist <path>:负向/夹具测试用(site/tests/test_s06.py),默认 site/dist
const argv = process.argv.slice(2);
let dist = join(siteRoot, "dist");
{
  const i = argv.indexOf("--dist");
  if (i !== -1) {
    if (i + 1 >= argv.length) throw new Error("--dist 须带目录参数");
    dist = resolve(argv[i + 1]);
  }
}

const MARKER = "# generated: pair canonicalization (gen-pair-redirects.mjs) — do not edit below";

if (!existsSync(dist)) {
  throw new Error(`dist 不存在:${dist}——本脚本须在 astro build 之后运行`);
}
const redirectsPath = join(dist, "_redirects");
if (!existsSync(redirectsPath)) {
  throw new Error(`_redirects 不存在:${redirectsPath}(public/_redirects 缺失或未随构建拷贝)`);
}

// slug → 天干序号,自 terms.json heavenlyStems 的 path 末段反推(甲 → jia-wood → 0)
const terms = JSON.parse(readFileSync(join(siteRoot, "src/data/terms.json"), "utf8"));
const stemSlugRank = new Map();
for (const [stem, t] of Object.entries(terms.groups.heavenlyStems)) {
  const slug = t.path.split("/").filter(Boolean).pop();
  if (stemSlugRank.has(slug)) {
    throw new Error(`terms.json heavenlyStems path 末段重复:${slug}`);
  }
  const rank = STEM_ORDER.indexOf(stem);
  if (rank < 0) {
    throw new Error(`terms.json 天干 ${stem} 不在 STEM_ORDER(${STEM_ORDER.join(",")})——两侧单一事实源漂移`);
  }
  stemSlugRank.set(slug, rank);
}

const rankToSlug = new Map([...stemSlugRank].map(([slug, r]) => [r, slug]));

function parsePair(slug) {
  const m = slug.match(/^(.+)-and-(.+)$/);
  if (!m) return null;
  const a = stemSlugRank.get(m[1]);
  const b = stemSlugRank.get(m[2]);
  if (a === undefined || b === undefined || a === b) return null;
  return { lo: Math.min(a, b), hi: Math.max(a, b), straight: a < b };
}

// Set 去重:正序页产出的反序别名规则,与反序文件自身产出的归一规则可能同一条
const rules = new Set();
for (const lang of ["en", "zh-hant"]) {
  const dir = join(dist, lang, "compatibility");
  if (!existsSync(dir)) continue;
  for (const name of readdirSync(dir).sort()) {
    if (!name.endsWith(".html")) continue;
    const slug = name.replace(/\.html$/, "");
    const pair = parsePair(slug);
    if (!pair) {
      throw new Error(
        `${lang}/compatibility/${name}: slug 解析不出两个不同天干(命名约定 <stem>-and-<stem>,slug 取 terms.json path 末段)`
      );
    }
    const canonical = `${rankToSlug.get(pair.lo)}-and-${rankToSlug.get(pair.hi)}`;
    // 反序文件:自身 301 到正序页
    if (!pair.straight) {
      rules.add(`/${lang}/compatibility/${slug} /${lang}/compatibility/${canonical} 301`);
    }
    // 正序页:产出反序别名规则(反序 URL 没有对应文件也要能 301 到这里)
    const reverse = `${rankToSlug.get(pair.hi)}-and-${rankToSlug.get(pair.lo)}`;
    rules.add(`/${lang}/compatibility/${reverse} /${lang}/compatibility/${canonical} 301`);
  }
}
const lines = [...rules].sort();

// 幂等:重跑替换 marker 之后的生成段,marker 之前(手写规则)原样保留
const base = readFileSync(redirectsPath, "utf8");
const kept = base.includes(MARKER) ? base.slice(0, base.indexOf(MARKER)) : (base.endsWith("\n") ? base : base + "\n");
const block = lines.length === 0
  ? ""
  : `${MARKER}\n${lines.join("\n")}\n`;
writeFileSync(redirectsPath, kept + block);
console.log(`gen-pair-redirects: ${lines.length} 条归一规则`);
