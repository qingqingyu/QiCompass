# TASK-21 官网字体收录「随日期变化的字」(节气 / 干支)+ 产物缺字重建

> 2026-11-28 外部 review 新发现(复核 TASK-18/19/20 时顺带查出)。与 TASK-18/19/20 同批收口。

## 问题(review 发现)

1. **定时复发(结构性)**:en 首页「今日」条按日期渲染当前节气名与年/月/日三柱干支
   (`site/src/pages/en/index.astro` L114–121)。字体 SC 腿 2026-11-28 起改扫**构建产物**,
   而产物只含**构建当天**的值——24 个节气名用字缺 20 个。下一次触发是 **2026-12-21
   「冬至」**:两字都不在 `knowfate-sc.woff2` 里,会掉系统字体顶替。每日定时重建只换
   页面不换字体,`--verify` 也只看当天页面,平时报不出来。
2. **当前即失败**:S04/S05 内容合入后字体没有重建——SC 缺「或」「案」(en 首页在用),
   TC 缺「折」(zh-hant 源文件在用),`build_site_fonts.py --verify` FAIL。
3. **附带**:五行生克图 `WuxingCycle.astro` 客户端 `<script>` 里两条中文报错会随内联
   脚本打进 en 页面产物,又被字体 SC 腿(扫 dist)当成正文用字收进子集。

## 修法(commit `22ee9d1`)

- `tools/build_site_fonts.py` 新增 `en_date_varying_chars()`:从 `site/src/data/calendar.json`
  (后端引擎确定性导出,400 天窗)整体收**全部节气名 + 全部干支字**进 SC 硬性集合——
  与 `en_rendered_term_chars()`(天干点缀)同思路:不靠构建当天的巧合。附断言:节气
  必须 24 个、干支字必须 22 个(十干+十二支),导出窗缩短导致覆盖不全直接 FAIL,
  不静默产出缺字字体(错误显式传播)。
- `WuxingCycle.astro` 两条内联报错改英文(frontmatter 里的构建期报错不进产物,维持
  中文不动);`KitchenSink.astro` 硬编码的 Buttondown 订阅 URL 改用 `BUTTONDOWN_ACTION`
  单一事实源(占位 list 名换真实名时不再漏改样张页)。
- 重建五枚 woff2:SC 268→281 字形(61.8→65.6 KB,+3.8 KB 换全年日期变字全覆盖);
  TC 1631 字全过。

## 为什么 TC 腿不需要同样的修法

TC 腿扫**源码**:`calendar.json` 作为共享文件本来就整体进 TC 扫描,全部日期变字
(含 `jieqiHant` 映射的繁体名)已在内——缺「折」只是没重建,不是口径缺口。

## 验收

- `python3 tools/build_site_fonts.py --verify` PASS(SC 258/258、TC 1253/1253)
- `python3 tools/check_site_content.py` PASS;`cd site && npm run build` 16 页通过
- `node --test site/tests/launch.test.mjs` 18 过;`python3 -I site/tests/test_launch.py` 5 过
- 12-21「冬至」用字已入字体(节气 24 名整体收录,不依赖当天)
