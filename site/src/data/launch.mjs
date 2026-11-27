// 上线开关匹配核心(纯逻辑,零依赖;TASK-18 单一事实源配套)。
//
// 为什么是 .mjs:site.ts(Vite 侧)与 site/tests/launch.test.mjs(裸 Node 侧)
// 都要执行同一份匹配实现——TS 文件裸 Node 导入不了,双写必然漂移
// (先例:config.mjs 的双端 import 理由)。site.ts 只做包装
// (加载 launch.json → matchSection),Python 侧 tools/check_site_content.py
// 按 launch.d.mts 同一 docstring 规则另有一份实现,行为一致性由两侧
// 共读的 site/tests/fixtures/launch-cases.json 锁定。
//
// 匹配规则(TS / Python 两侧必须逐字一致):
//   命中某 prefix 当且仅当 rest === prefix 或 rest.startsWith(prefix + "/")。
//   不做「前缀 + 连字符」匹配(/day-master 关闭时 /day-master-calculator
//   不受它门控——2026-11-27 外评第 1 条误伤的根源)。
//   一个 rest 同时命中多条 prefix 时,取最长 prefix 所属区块(单字符前缀
//   撞车保护);未命中任何区块的路径视为已上线(首页、语言根、未登记页)。

/**
 * @typedef {{ enabled: boolean, prefixes: string[] }} LaunchSection
 * @typedef {Record<string, LaunchSection>} LaunchSections
 */

/**
 * 判断 rest(不带语言前缀的路径)是否已上线。
 *
 * @param {LaunchSections} sections launch.json 的 sections 表
 * @param {string} rest 不带语言前缀的路径(如 "/day-master/jia-wood")
 * @returns {boolean} 未命中任何区块 → true;命中 → 所属区块的 enabled
 */
export function matchSection(sections, rest) {
  let launched = true;
  let bestLen = -1;
  for (const sec of Object.values(sections)) {
    for (const p of sec.prefixes) {
      const hit = rest === p || rest.startsWith(p + "/");
      if (hit && p.length > bestLen) {
        launched = sec.enabled;
        bestLen = p.length;
      }
    }
  }
  return launched;
}
