// remark-term-links 单测(S02 验收:同一术语只链首次;标题里不链;已有链接不重复包;
// 本页自身不链;data-* 属性齐全)。运行:node --test site/tests/remark-terms.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { unified } from "unified";
import remarkParse from "remark-parse";
import { VFile } from "vfile";
import remarkTermLinks from "../src/plugins/remark-term-links.mjs";

const terms = JSON.parse(
  readFileSync(new URL("../src/data/terms.json", import.meta.url), "utf-8"),
);

const processor = (opts = {}) =>
  unified().use(remarkParse).use(remarkTermLinks, { terms, defs: { 比肩: "The stem equal to the Day Master." }, ...opts });

async function transform(md, { path = "/proj/src/content/guides/en/some-guide.md", frontmatter = {} } = {}) {
  const vfile = new VFile({ value: md, path, data: { astro: { frontmatter } } });
  const proc = processor();
  const tree = proc.parse(vfile);
  // run 必须收到同一个 vfile:插件从 file.history / file.data.astro 读页面上下文
  return proc.run(tree, vfile);
}

function termLinks(node, out = []) {
  if (node.type === "link" && node.data?.hProperties?.class === "term") {
    out.push(node);
  }
  if (Array.isArray(node.children)) {
    for (const child of node.children) termLinks(child, out);
  }
  return out;
}

function plainText(node) {
  if (node.type === "text") return node.value;
  return Array.isArray(node.children) ? node.children.map(plainText).join("") : "";
}

const EN_BODY = "The Companion is the first god. Another Companion appears later.";

test("同一术语只链首次出现", async () => {
  const tree = await transform(EN_BODY);
  const links = termLinks(tree);
  assert.equal(links.length, 1);
  assert.equal(links[0].url, "/en/ten-gods/companion");
  assert.match(plainText(tree), /Another Companion appears later/);
  // roundtrip 相等:链接包入不得增删或重复任何正文文本(回归:splice 曾用字符偏移当
  // 数组下标,越界追加导致整段重复渲染,弱断言拦不住)
  assert.equal(plainText(tree), EN_BODY);
});

test("标题里不链,正文链", async () => {
  const tree = await transform("# Companion\n\nThe Companion is here.");
  const links = termLinks(tree);
  assert.equal(links.length, 1);
  const heading = tree.children[0];
  assert.equal(heading.type, "heading");
  assert.ok(!termLinks(heading).length);
});

test("标题里的加粗术语也不链(阻断沿子树传播)", async () => {
  const tree = await transform("## The **Companion** is here.\n\nBody text with Companion too.");
  const heading = tree.children[0];
  assert.ok(!termLinks(heading).length, "heading > strong > text 也不得包链");
  const links = termLinks(tree);
  assert.equal(links.length, 1, "正文里的同一术语照常包链");
  assert.equal(links[0].url, "/en/ten-gods/companion");
});

test("已有链接不重复包,且消耗首次出现", async () => {
  const md = "Read [Companion](/en/ten-gods/companion) first; a later Companion stays plain.";
  const tree = await transform(md);
  const links = termLinks(tree);
  assert.equal(links.length, 0, "手写链接已消耗该术语,后文不再自动包链");
  assert.equal(plainText(tree), "Read Companion first; a later Companion stays plain.");
});

test("本页自身不链(按文件路径推导)", async () => {
  const tree = await transform("The Companion describes equals.", {
    path: "/proj/src/content/ten-gods/en/companion.md",
  });
  assert.equal(termLinks(tree).length, 0);
});

test("selfTermKeys 也能屏蔽", async () => {
  const tree = await transform("The Companion describes equals.", {
    frontmatter: { selfTermKeys: ["比肩"] },
  });
  assert.equal(termLinks(tree).length, 0);
});

test("data-zh / data-title / data-def 齐全;缺 def 时不带 data-def", async () => {
  const body = "The Companion is here.";
  const withDef = termLinks(await transform(body))[0];
  assert.equal(withDef.data.hProperties["data-zh"], "比肩");
  assert.equal(withDef.data.hProperties["data-title"], "Companion");
  assert.equal(withDef.data.hProperties["data-def"], "The stem equal to the Day Master.");

  const noDefs = unified().use(remarkParse).use(remarkTermLinks, { terms, defs: {} });
  const vfile = new VFile({ value: body, path: "/p/src/content/guides/en/x.md" });
  const noDef = termLinks(await noDefs.run(noDefs.parse(vfile), vfile))[0];
  assert.equal(noDef.data.hProperties["data-def"], undefined);
});

test("英文整词边界:companionship 不链", async () => {
  const tree = await transform("Companionship is not the term.");
  assert.equal(termLinks(tree).length, 0);
});

test("zh-hant 页面按 zhHant 匹配", async () => {
  const body = "比肩在命盤裡出現,後面又一次比肩不重複。";
  const tree = await transform(body, {
    path: "/proj/src/content/guides/zh-hant/x.md",
    frontmatter: { lang: "zh-hant" },
  });
  const links = termLinks(tree);
  assert.equal(links.length, 1);
  assert.equal(links[0].url, "/zh-hant/ten-gods/companion");
  assert.equal(links[0].data.hProperties["data-zh"], "比肩");
  assert.equal(plainText(tree), body, "zh-hant 链接包入后正文逐字不变");
});

test("最长匹配优先,术语不嵌套", async () => {
  // "Direct Wealth" 与 "Direct Officer" 共享前缀词 "Direct";都命中时各自独立成链
  const body = "Direct Wealth and Direct Officer both appear.";
  const tree = await transform(body);
  const links = termLinks(tree);
  assert.equal(links.length, 2);
  assert.equal(plainText(tree), body, "两个术语链入后正文逐字不变");
});

test("段中首次出现(多子节点兄弟)不吞不重:roundtrip 逐字相等", async () => {
  // 手写链接占 child[1];术语在其后兄弟文本节点里 hitAt=9 ≠ child 下标 2
  // (回归:splice 曾用 hitAt 当数组下标,吞兄弟/越界追加)
  const body = "See [the library](/en/library); then Companion appears here.";
  const tree = await transform(body);
  assert.equal(plainText(tree), "See the library; then Companion appears here.");
  const links = termLinks(tree);
  assert.equal(links.length, 1);
  assert.equal(links[0].url, "/en/ten-gods/companion");
});

test("位置更早的术语不被后评估匹配器丢弃", async () => {
  // "Direct Officer" 首个出现比 "Eating God" 晚;评估序按长度倒序,
  // 早出现者仍应先链(回归:非全局正则首个命中 < best.index 即 -1 曾整页漏链)
  const body = "The Eating God meets a Direct Officer.";
  const tree = await transform(body);
  const links = termLinks(tree);
  assert.equal(links.length, 2, "两个术语各自链首次出现");
  assert.equal(links[0].url, "/en/ten-gods/eating-god", "先链位置更早的");
  assert.equal(plainText(tree), body);
});
