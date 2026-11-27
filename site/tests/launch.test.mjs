// TASK-18(2026-11-27):matchSection(launch.mjs)行为用例 + 真实 launch.json 结构校验。
// 与 site/tests/test_launch.py 共读同一份 fixtures/launch-cases.json——TS 与 Python
// 各有一份匹配实现,同一组向量全量对齐,任何一侧单独改动都会在此暴露。
// 运行:node --test site/tests/launch.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { matchSection } from "../src/data/launch.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  readFileSync(join(here, "fixtures", "launch-cases.json"), "utf8"),
);

/** 用例只声明「开启」的区块名单,其余区块组装成关闭(enabled 与 prefixes 合成完整表)。 */
function sectionsFor(enabled) {
  return Object.fromEntries(
    Object.entries(fixture.sections).map(([name, sec]) => [
      name,
      { enabled: enabled.includes(name), prefixes: sec.prefixes },
    ]),
  );
}

for (const c of fixture.cases) {
  test(c.name, () => {
    assert.equal(
      matchSection(sectionsFor(c.enabled), c.rest),
      c.expect,
      `rest=${c.rest} enabled=[${c.enabled.join(", ")}]`,
    );
  });
}

test("真实 launch.json:结构可被 matchSection 消费(enabled bool + prefixes 非空「/…」)", () => {
  const real = JSON.parse(
    readFileSync(join(here, "..", "src", "data", "launch.json"), "utf8"),
  );
  assert.ok(real.sections && Object.keys(real.sections).length > 0, "sections 须非空");
  // 与 tools/check_site_content.py load_launch_sections 的结构校验同口径
  // (尾斜杠 no-op / 跨区块重复前缀都显式拒绝),一侧加规则另一侧须同步。
  const seen = new Map();
  for (const [name, sec] of Object.entries(real.sections)) {
    assert.equal(typeof sec.enabled, "boolean", `区块 ${name}.enabled 须为 bool`);
    assert.ok(
      Array.isArray(sec.prefixes) && sec.prefixes.length > 0,
      `区块 ${name}.prefixes 须为非空数组`,
    );
    for (const p of sec.prefixes) {
      assert.match(p, /^\/.+$/, `区块 ${name} 前缀须为 "/…" 形态`);
      assert.ok(!p.endsWith("/"), `区块 ${name} 前缀 ${p} 以 / 结尾——匹配规则永远不命中(静默 no-op),去掉尾斜杠`);
      assert.ok(!seen.has(p), `launch.json 前缀 ${p} 重复登记于区块 ${seen.get(p)} 与 ${name}——一个路由前缀只能归属一个区块`);
      seen.set(p, name);
    }
  }
});
