// 文章 H2 处理(S03):`## 壹|标题` → 赋锚点 id + 把大写数字拆进 .numeral 圆。
// 与 lib/headings.mjs 共用解析(id 同函数同序号;页面 TOC 用同一函数从 raw
// markdown 推导,两侧必然一致)。不含该约定的 h2 一律不动(kitchen-sink 等
// 模板页的普通 h2 不受影响)。
//
// 执行顺序(已核对 @astrojs/markdown-remark dist):用户 rehype 插件先跑,
// Astro 的 rehypeHeadingIds 最后跑且**尊重已有 id**(properties.id 已是 string
// 就不覆盖)——所以本文赋的 id 就是最终 DOM id,TOC 锚点成立。
import { parseH2, h2Id, uniqueH2Id } from "../lib/headings.mjs";

function textOf(node) {
  if (node.type === "text") return node.value;
  if (Array.isArray(node.children)) return node.children.map(textOf).join("");
  return "";
}

export default function rehypeArticleHeadings() {
  return function (tree) {
    let ordinal = 0;
    const seenIds = new Map();
    (function walk(node) {
      if (!Array.isArray(node.children)) return;
      for (const child of node.children) {
        if (
          child.type === "element" &&
          child.tagName === "h2" &&
          Array.isArray(child.children) &&
          // 只处理纯文本标题(含内联元素的标题不动,避免吞掉链接/强调)
          child.children.every((c) => c.type === "text")
        ) {
          const parsed = parseH2(textOf(child));
          if (parsed) {
            ordinal += 1;
            // 同题章节去重(sectionTocFromBody 同函数同顺序,两侧 id 一致)
            const id = uniqueH2Id(h2Id(parsed.title, ordinal), seenIds);
            child.properties = { ...(child.properties ?? {}), id };
            child.children = [
              {
                type: "element",
                tagName: "span",
                properties: { className: ["numeral"] },
                children: [{ type: "text", value: parsed.numeral }],
              },
              { type: "text", value: parsed.title },
            ];
          }
        }
        walk(child);
      }
    })(tree);
  };
}
