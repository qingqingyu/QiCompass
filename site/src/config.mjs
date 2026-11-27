// 全站功能/转化开关单一事实源(S03 建骨架,S05 接 NotifyOrAppStore 与站务页)。
// 两期之间只改这里的值,模板与 CTA 组件不分叉(规格 README §12:prelaunch ↔ live 只换配置)。
// 为什么是 .mjs 而不是 .ts:astro.config.mjs(Node 侧)与 .astro 组件(Vite 侧)
// 都要 import 它;纯 JS 两边零转换直接可用。

export const CONFIG = {
  /** 排盘器页:一期 'off'(页内 CTA 目标改 Library,排盘器页是锁框版);
   *  S09-S12 落地后翻 'on'(CTA 直指 /bazi-calculator)。 */
  features: { calculator: "off" }, // 'off' | 'on'
  /** 转化两态:'prelaunch' = Buttondown 邮箱表单;'live' = App Store / 排盘 CTA。 */
  cta: { state: "prelaunch" }, // 'prelaunch' | 'live'
  /** cta.state = 'live' 时必填(运营提供正式 App Store 链接);prelaunch 下留空。 */
  appStoreUrl: "",
  /** Buttondown 邮件列表名(HITL,S05:用户注册后替换成真实 list 名)。 */
  buttondownList: "qicompass",
};

// 错误显式传播:翻到 live 却没配 App Store 链接 = 全站 CTA 指向空地址,宁可构建期炸
if (CONFIG.cta.state === "live" && !CONFIG.appStoreUrl) {
  throw new Error(
    "config.mjs: cta.state='live' 需要 appStoreUrl(运营提供);不配置就保持 'prelaunch'"
  );
}
if (!["off", "on"].includes(CONFIG.features.calculator)) {
  throw new Error(`config.mjs: features.calculator 取值非法 ${CONFIG.features.calculator}`);
}
if (!["prelaunch", "live"].includes(CONFIG.cta.state)) {
  throw new Error(`config.mjs: cta.state 取值非法 ${CONFIG.cta.state}`);
}
