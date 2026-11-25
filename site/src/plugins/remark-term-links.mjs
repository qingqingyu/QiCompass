// 术语自动内链 remark 插件(S02 #4)。仓库内使用,不发包。
//
// 规则(规格 §5 内链):
//   - 正文里每个术语的**首次出现**包成 <a class="term" data-zh data-title data-def href>;
//     def 来自 site/src/data/term-defs.json(缺 → 不带 data-def,释义卡自然不激活)
//   - 标题(heading)里不链;已有链接(link)内部不重复包;code/inlineCode 不链
//   - 本页自身不链:按文件路径推导本页 URL,自动跳过;另支持 frontmatter selfTermKeys
//   - 同一匹配串被更长术语占用时让位(最长匹配优先),术语之间不嵌套
//
// 匹配面(S02 默认,CONTENT_GUIDE.md 有说明):
//   en 页面:tenGods / shensha / fiveElements 的 en 名(区分大小写 + 词边界;
//     干支拼音单字组不参与——"Wu" 同时是 戊(天干)与 午(地支),"Yin" 又是
//     寅与阴阳的 yin,裸词匹配必然误链;日主/地支的链接由上下文手写,S03 起)
//   zh-hant 页面:tenGods / shensha 的 zhHant(全部 ≥2 字,复合词风险低;
//     五行单字 木火土金水 在中文复合词(甲木/木火通明)里必然误切,不参与)

const LINKABLE_GROUPS_EN = new Set(["tenGods", "shensha", "fiveElements"]);
const LINKABLE_GROUPS_HANT = new Set(["tenGods", "shensha"]);
// 术语组 → 页面语言前缀以外的路径已在 terms.json 里(path 含 {lang} 之前的部分)

/**
 * @param {object} options
 * @param {object} options.terms   site/src/data/terms.json 的解析结果
 * @param {Record<string, string>} options.defs  术语键 → 英文定义(缺省 {})
 */
export default function remarkTermLinks({ terms, defs = {} }) {
  const matchers = {
    en: buildMatchers(terms, "en", LINKABLE_GROUPS_EN, defs),
    "zh-hant": buildMatchers(terms, "zh-hant", LINKABLE_GROUPS_HANT, defs),
  };

  return function (tree, file) {
    const frontmatter = file.data?.astro?.frontmatter ?? {};
    const lang = frontmatter.lang === "zh-hant" ? "zh-hant" : "en";
    const active = matchers[lang];
    if (active.length === 0) return;

    // 本页 URL:src/content/{type}/{lang}/{slug}.md → /{lang}/{type}/{slug}
    const filePath = String(file.history?.[0] ?? file.path ?? "");
    const selfUrl = selfUrlFromPath(filePath);
    const selfKeys = new Set(frontmatter.selfTermKeys ?? []);
    const alreadyLinked = new Set();

    // 手写链接消耗首次出现:链接目标 = 某术语页 → 该术语不再自动包链(每术语每页只链一次)
    const hrefOwners = new Map();
    for (const m of active) {
      for (const l of ["en", "zh-hant"]) hrefOwners.set(m.href(l), m.key);
    }
    walkPass(tree, (node) => {
      if (node.type === "link") {
        const owner = hrefOwners.get(node.url);
        if (owner) alreadyLinked.add(owner);
      }
    });

    walk(tree, (node, parent, index) => {
      if (node.type !== "text" || !node.value) return false;
      const text = node.value;
      let best = null; // { index, length, matcher };length = 实际匹配跨度(en 词间 \s+ 可能比规范串长)
      for (const m of active) {
        if (alreadyLinked.has(m.key) || selfKeys.has(m.key)) continue;
        if (selfUrl && m.href(lang) === selfUrl) continue; // 本页自身不链
        const at = findMatch(text, m);
        if (at === null) continue;
        if (!best || at.index < best.index || (at.index === best.index && at.length > best.length)) {
          best = { index: at.index, length: at.length, matcher: m };
        }
      }
      if (!best) return false;
      const { index: hitAt, length: hitLen, matcher } = best;
      alreadyLinked.add(matcher.key);

      const linkNode = {
        type: "link",
        url: matcher.href(lang),
        title: null,
        children: [{ type: "text", value: text.slice(hitAt, hitAt + hitLen) }],
        data: {
          hName: "a",
          hProperties: {
            class: "term",
            "data-zh": matcher.zh,
            "data-title": matcher.title,
            ...(matcher.def ? { "data-def": matcher.def } : {}),
          },
        },
      };
      const nodes = [];
      if (hitAt > 0) nodes.push({ type: "text", value: text.slice(0, hitAt) });
      nodes.push(linkNode);
      if (hitAt + hitLen < text.length) {
        nodes.push({ type: "text", value: text.slice(hitAt + hitLen) });
      }
      // ⚠️ 必须用 child 下标(index 参数)splice;hitAt 是**字符偏移**,拿它当数组
      // 下标会越界追加(整段重复渲染)或吞掉兄弟节点——曾在此翻过车,勿回退
      parent.children.splice(index, 1, ...nodes);
      return true; // 重建过,当前节点作废
    });
  };
}

function buildMatchers(terms, lang, groups, defs) {
  const out = [];
  for (const [group, entries] of Object.entries(terms.groups)) {
    if (!groups.has(group)) continue;
    for (const [key, t] of Object.entries(entries)) {
      if (!t.path) continue;
      const match = lang === "zh-hant" ? t.zhHant : t.en;
      if (!match || !match.trim()) continue;
      out.push({
        key,
        group,
        match,
        zh: key,
        title: t.en,
        def: defs[key] ?? null,
        ascii: lang === "en",
        // en 名含空格(Rob Wealth)→ 词边界正则逐段转义;非 global(exec 恒从 0 起,
        // 无 lastIndex 共享状态)
        re: lang === "en" ? new RegExp(`\\b${match.split(" ").map(escapeRe).join("\\s+")}\\b`) : null,
        href: (l) => `/${l}${t.path}`,
      });
    }
  }
  // 长词优先:同起点时更长的术语赢(避免 "Wood" 抢走 "Wood …" 复合名)
  return out.sort((a, b) => b.match.length - a.match.length);
}

/** 返回 m 在 text 内的首个命中 {index, length},无则 null。
 *  语义恒为「全文首个命中」(不接 fromLeft)——外层每轮链接后拆分节点重扫,
 *  拆出的前缀/尾段各自再取全局最小首现,无需位移参数。
 *  en 命中可能是 m.match 的 `\s+` 变体,length 必须取实际匹配跨度而非规范串长。 */
function findMatch(text, m) {
  if (m.ascii) {
    const hit = m.re.exec(text);
    return hit ? { index: hit.index, length: hit[0].length } : null;
  }
  const at = text.indexOf(m.match);
  return at === -1 ? null : { index: at, length: m.match.length };
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** 全树先序遍历(无替换语义):cb 对每个节点调用一次。 */
function walkPass(node, cb) {
  cb(node);
  if (Array.isArray(node.children)) {
    for (const child of node.children) walkPass(child, cb);
  }
}

/**
 * 深度优先遍历;heading/link/image/code/inlineCode 子树内(含嵌套容器,如
 * 标题里的加粗)不参与链接,阻断状态沿递归向下传播。
 * cb 返回 true 表示 children 被重建,当前 index 的节点已是下一个,不前进。
 */
function walk(node, cb) {
  const skipSubtree = new Set(["heading", "link", "image", "code", "inlineCode"]);
  const visitChildren = (parent, blockedAbove) => {
    if (!parent.children || !Array.isArray(parent.children)) return;
    const blocked = blockedAbove || skipSubtree.has(parent.type);
    for (let i = 0; i < parent.children.length; ) {
      const child = parent.children[i];
      let replaced = false;
      if (!blocked) {
        replaced = cb(child, parent, i);
        if (replaced) {
          // cb 在 index 处 splice 了 1→N 个节点;对拆出的前缀 text 继续尝试匹配
          // (尾部文本会在后续迭代里被 cb 再处理)
          continue;
        }
      }
      visitChildren(child, blocked);
      i += 1;
    }
  };
  visitChildren(node, false);
}

/** src/content/{type}/{lang}/{slug}.md → /{lang}/{type}/{slug};非该形态返回 null。 */
function selfUrlFromPath(filePath) {
  const m = filePath.match(/src[\\/]content[\\/]([^\\/]+)[\\/](en|zh-hant)[\\/]([^\\/]+)\.md$/);
  if (!m) return null;
  return `/${m[2]}/${m[1]}/${m[3]}`;
}
