// 文章 H2 约定(CONTENT_GUIDE.md)的共享解析:正文 `## 壹|标题`。
// 单一事实源——rehype 插件(给 h2 赋 id + 拆大写数字圆)与页面(从 raw markdown
// 推导 TOC)都调这里的函数,对同一标题必然得到同一 id,目录锚点才对得上。
// 两套大写数字:en 腿 SC(贰叁陆),zh-hant 腿 Big5 安全字(貳參陸)——
// TC 子集缺 贰/叁/陆 三字形(与 KitchenSink 的 numerals 表同一结论)。

const H2_RE = /^##\s+([壹貳贰參叁肆伍陸陆柒捌])\|(.+)$/;

/** `## 壹|What it describes`(raw markdown)或 `壹|What it describes`(hast 里
 *  remark 已吃掉 `## ` 前缀的 h2 文本)→ { numeral, title };非约定形态 → null。 */
export function parseH2(text) {
  const m = H2_RE.exec(text.trim()) ?? /^([壹貳贰參叁肆伍陸陆柒捌])\|(.+)$/.exec(text.trim());
  if (!m) return null;
  return { numeral: m[1], title: m[2].trim() };
}

/** 标题 → 锚点 id:latin 连字符 slug;纯中文标题回退 sec-{序号}。
 *  序号 = 该文件内第几个命中约定的 h2(从 1 起)——与解析顺序同源,不会漂移。 */
export function h2Id(title, ordinal) {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || `sec-${ordinal}`;
}

/** 同页 id 去重:同 slug 的第 n 次(n ≥ 2)出现追加 -n。rehype 插件与 TOC 推导
 *  必须用同一函数、同一顺序调用,目录锚点才与 h2 最终 id 一致。 */
export function uniqueH2Id(base, seenIds) {
  const n = (seenIds.get(base) ?? 0) + 1;
  seenIds.set(base, n);
  return n === 1 ? base : `${base}-${n}`;
}

/** 从 raw markdown 正文推导目录项(numeral/title/id)。
 *  供页面层渲染左栏 TOC;id 与 rehype 插件赋的 id 同函数同序号,必然一致。 */
export function sectionTocFromBody(body) {
  const out = [];
  const seenIds = new Map();
  for (const line of body.split("\n")) {
    const m = H2_RE.exec(line.trim());
    if (!m) continue;
    const ordinal = out.length + 1;
    const title = m[2].trim();
    out.push({ numeral: m[1], title, id: uniqueH2Id(h2Id(title, ordinal), seenIds) });
  }
  return out;
}
