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
});

test("标题里不链,正文链", async () => {
  const tree = await transform("# Companion\n\nThe Companion is here.");
  const links = termLinks(tree);
  assert.equal(links.length, 1);
  const heading = tree.children[0];
  assert.equal(heading.type, "heading");
  assert.ok(!termLinks(heading).length);
});

test("已有链接不重复包,且消耗首次出现", async () => {
  const md = "Read [Companion](/en/ten-gods/companion) first; a later Companion stays plain.";
  const tree = await transform(md);
  const links = termLinks(tree);
  assert.equal(links.length, 0, "手写链接已消耗该术语,后文不再自动包链");
  assert.ok(plainText(tree).includes("a later Companion stays plain"));
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
  const withDef = termLinks(await transform("The Companion is here."))[0];
  assert.equal(withDef.data.hProperties["data-zh"], "比肩");
  assert.equal(withDef.data.hProperties["data-title"], "Companion");
  assert.equal(withDef.data.hProperties["data-def"], "The stem equal to the Day Master.");

  const noDefs = unified().use(remarkParse).use(remarkTermLinks, { terms, defs: {} });
  const vfile = new VFile({ value: "The Companion is here.", path: "/p/src/content/guides/en/x.md" });
  const noDef = termLinks(await noDefs.run(noDefs.parse(vfile), vfile))[0];
  assert.equal(noDef.data.hProperties["data-def"], undefined);
});

test("英文整词边界:companionship 不链", async () => {
  const tree = await transform("Companionship is not the term.");
  assert.equal(termLinks(tree).length, 0);
});

test("zh-hant 页面按 zhHant 匹配", async () => {
  const tree = await transform("比肩在命盤裡出現,後面又一次比肩不重複。", {
    path: "/proj/src/content/guides/zh-hant/x.md",
    frontmatter: { lang: "zh-hant" },
  });
  const links = termLinks(tree);
  assert.equal(links.length, 1);
  assert.equal(links[0].url, "/zh-hant/ten-gods/companion");
  assert.equal(links[0].data.hProperties["data-zh"], "比肩");
  assert.ok(plainText(tree).includes("後面又一次比肩不重複"));
});

test("最长匹配优先,术语不嵌套", async () => {
  // "Direct Wealth" 与 "Direct Officer" 共享前缀词 "Direct";都命中时各自独立成链
  const tree = await transform("Direct Wealth and Direct Officer both appear.");
  const links = termLinks(tree);
  assert.equal(links.length, 2);
});
