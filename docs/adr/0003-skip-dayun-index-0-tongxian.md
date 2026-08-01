# 0003 — 大运 `index=0` 童限跳过,前端从 `index=1` 起

Status: accepted (2026-07-09)

`lunar_python` `getYun(gender).getDaYun()` 返回的大运数组,第一步 `index=0` 的 `ganZhi=""`(空字符串),代表起运前的童限过渡。前端展示必须从 `index=1` 开始,跳过 `index=0`。

**Why**: 库的设计是给"完整生命周期"留一个空位标记起运前。前端如果直接渲染 `index=0` 会显示空干支柱,用户困惑;如果传给 LLM 让它"解读空字符串"会引发幻觉。

**Surprising without context**: 任何遍历 `getDaYun()` 的代码必须 `for i in range(1, len(...))` 或 `da_yun[1:]`,看起来像 off-by-one bug,其实是库语义。后端 API 契约里 `luck_pillars` 字段已经做了跳过,但客户端如果直接拿 `getDaYun()` 输出会踩坑。

**Consequences**: 后端 `/api/bazi/calculate` 必须在序列化前 filter 掉 `ganZhi == ""` 的元素,或在响应里保留但加 `is_tongxian: true` 标记。MVP 选前者(直接跳过)。
