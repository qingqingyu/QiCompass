// Astro 5 content collections(S02 #3)。每种页面类型一个 collection。
// 术语枚举(stem/god/star/element)直接取自 src/data/terms.json——单一事实源,
// backend 改词 → 重跑 export_site_terms.py → 枚举自动跟随,无第二处词表。
// reviewedBy 门槛是 superRefine(构建失败,不是警告):published: true 必须有人工过目记录。
// 结构注意:superRefine 返回 ZodEffects(没有 .extend),所以 refine 必须放在
// 每个 collection 的 extend() **之后**统一挂 refineBase,不能挂在 base 上。
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';
import terms from './data/terms.json';

const stemKeys = Object.keys(terms.groups.heavenlyStems) as [string, ...string[]];
const branchKeys = Object.keys(terms.groups.earthlyBranches) as [string, ...string[]];
const godKeys = Object.keys(terms.groups.tenGods) as [string, ...string[]];
const starKeys = Object.keys(terms.groups.shensha) as [string, ...string[]];
const elementKeys = Object.keys(terms.groups.fiveElements) as [string, ...string[]];

const dateStr = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, '日期格式 YYYY-MM-DD');
const isoMoment = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, '时刻格式 YYYY-MM-DDTHH:mm(北京时间)');
const urlSlug = z.string().regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/, 'slug 格式:小写字母数字加连字符');

// H2 章节约定(详见 CONTENT_GUIDE.md):正文用 `## 壹|人生主线` 形式,
// 模板按 `{中文数字}|{标题}` 拆分渲染大写数字编号;不用 frontmatter sections 数组。
const base = z.object({
  /** 页面主词(en ≤60 字符;zh-hant 同限,含标点)。品牌后缀「| 觀命 KnowFate」
   *  由布局层拼接,**超 60 时布局不加后缀**(规格 §6;拼接规则见 Base.astro →
   *  BaseHead.astro 的 fullTitle)——此处 60 是主词自身上限,不含后缀。 */
  title: z.string().min(1).max(60),
  /** meta description:一句完整回答,长度按语言分档(refineBase 校验)——
   *  en 140–160 字符(规格原口径);zh-hant 60–90 字(2026-11-27 外评修订:
   *  140–160 是英文搜索摘要口径,中文这么长会被搜索引擎截断,规格原稿未分语言) */
  description: z.string().min(1),
  /** URL slug;须与文件名一致(由 check_site_content.py 校验) */
  slug: urlSlug,
  /** 语言;须与目录段一致(src/content/{type}/{lang}/{slug}.md) */
  lang: z.enum(['en', 'zh-hant']),
  /** In short 答案框:en ≤60 词 / zh-hant ≤120 字(refineBase 校验) */
  inShort: z.string().min(1),
  /** 内容更新日期(非发布日期;JSON-LD dateModified 用) */
  updated: dateStr,
  /** 发布开关;true 必须有 reviewedBy(人工过目) */
  published: z.boolean().default(false),
  /** FAQ 2–4 条,与 FAQPage JSON-LD 一一对应(S03 模板落) */
  faq: z.array(z.object({ q: z.string().min(1), a: z.string().min(1) })).min(2).max(4),
  /** 人工过目记录;published: true 时非空(refineBase 强制) */
  reviewedBy: z
    .object({ date: dateStr, reviewer: z.string().min(1) })
    .nullable()
    .default(null),
  /** 本页自身的术语键(自动内链跳过;一般不需要手填——插件按页面 URL 自动跳过) */
  selfTermKeys: z.array(z.string()).default([]),
  /** 竖排题签(hero 右侧装饰,如「参天之木」;可选,≤8 字) */
  vtext: z.string().min(1).max(8).optional(),
});

function refineBase(data, ctx) {
  if (data.published && !data.reviewedBy) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['reviewedBy'],
      message: 'published: true 需要 reviewedBy(人工过目:日期 + 审阅人);缺审不许发布',
    });
  }
  // 长度分语言(2026-11-27 外评修订,原 140–160 为英文口径套全员)
  const descLimit = data.lang === 'zh-hant'
    ? { min: 60, max: 90, label: '60–90 字' }
    : { min: 140, max: 160, label: '140–160 字符' };
  if (data.description.length < descLimit.min || data.description.length > descLimit.max) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['description'],
      message: `description ${data.lang} 需 ${descLimit.label}(当前 ${data.description.length})`,
    });
  }
  // 正则端点一律用 \u 转义(2026-11-27 外评修复):字面区间端点(U+9FFF/U+FAFF
  // 等非映射码位)会被 build_site_fonts.py 当正文用字扫进硬性要求,字体必缺。
  const hasCJK = /[\u3000-\u9FFF\uF900-\uFAFF]/.test(data.inShort);
  if (hasCJK) {
    if (data.inShort.length > 120) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['inShort'], message: 'inShort 中文 ≤120 字(答案框定义句)' });
    }
  } else if (data.inShort.trim().split(/\s+/).length > 60) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['inShort'], message: 'inShort 英文 ≤60 词(答案框定义句)' });
  }
}

const dayMaster = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/day-master' }),
  schema: base
    .extend({
      /** 日主天干(甲…癸;术语枚举来自 terms.json) */
      stem: z.enum(stemKeys),
      element: z.enum(elementKeys),
      polarity: z.enum(['yang', 'yin']),
      /** OG 图 / 视觉素材引用(S06 OG 生成前可空) */
      image: z.string().optional(),
    })
    .superRefine(refineBase),
});

const tenGods = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/ten-gods' }),
  schema: base
    .extend({
      /** 十神(比肩…偏印;偏官与七杀同页) */
      god: z.enum(godKeys),
    })
    .superRefine(refineBase),
});

const fiveElements = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/five-elements' }),
  schema: base
    .extend({
      /** 五行(木火土金水;规格 §3 一批含 5 个总览页,S07 产出) */
      element: z.enum(elementKeys),
    })
    .superRefine(refineBase),
});

const stars = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/stars' }),
  schema: base
    .extend({
      /** 神煞(天乙贵人…红艳,20 个) */
      star: z.enum(starKeys),
      /** 查法一句话(按日干或年支查表;《三命通会》单一来源) */
      lookupBasis: z.string().min(1),
    })
    .superRefine(refineBase),
});

const guides = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/guides' }),
  schema: base
    .extend({
      /** 阅读时长(分钟;首页 Guides 列表展示) */
      readingMinutes: z.number().int().positive(),
    })
    .superRefine(refineBase),
});

const zodiac = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/zodiac' }),
  schema: base
    .extend({
      /** 生肖(地支与生肖合一,规格 §3) */
      animal: z.string().min(1),
      /** 地支(子…亥) */
      branch: z.enum(branchKeys),
      element: z.enum(elementKeys),
      /** 好朋友(六合 1 + 三合 2)/ 需磨合(六冲 1):构建期从后端 branch_relations.py
       *  导出的 terms.json branchRelations 取,不手填;手填值若与导出不一致
       *  由 check_site_content.py FAIL(frontmatter 可整字段省略) */
      friends: z.array(z.string()).optional(),
      clash: z.string().optional(),
    })
    .superRefine(refineBase),
});

const zodiacYear = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/zodiac-year' }),
  schema: base
    .extend({
      /** 年份(公历) */
      year: z.number().int(),
      /** 该年年柱干支(2 字,如 丙午;端点 \u 转义,同上) */
      yearPillar: z.string().regex(/^[\u4e00-\u9fff]{2}$/, '年柱干支 2 个汉字(区间端点用转义写法,同 hasCJK 注)'),
      /** 起止 = 立春到次年立春(北京时间;引擎导出,不手填) */
      startsAt: isoMoment,
      endsAt: isoMoment,
    })
    .superRefine(refineBase),
});

export const collections = {
  'day-master': dayMaster,
  'ten-gods': tenGods,
  'five-elements': fiveElements,
  stars,
  guides,
  zodiac,
  'zodiac-year': zodiacYear,
};
