# S06 本地 Web UI 与首轮基线

> **2026-08-26 注记**:App 设计已换轨水墨孤本;evalkit WebUI 为内部工具,**沿用本文旧宋瓷配色
> 不跟随换轨**(避免动 evalkit 代码触发不必要回归),如后续统一再单独立项。


- **类型**: AFK
- **Blocked by**: S04(S05 落地后收尾最佳)
- **覆盖决策**: Q2(独立本地服务)、Q8(UI)、Q9(落地与守护栏)
- **Parent**: `docs/prompt评测机设计决策.md`

## What to build

### 1. `backend/evalkit/server.py` — 独立本地 FastAPI app

```
uvicorn evalkit.server:app --host 127.0.0.1 --port 8899
```

- **独立 app,不复用 `app.main`**(Q2):评测路由与生产路由同进程会带来"dev 开关漏关"的泄漏风险,且跑批会占用生产 app 的事件循环
- **只监听 127.0.0.1,无鉴权,不进生产镜像**——本地工具。`server.py` 顶部 docstring 明写这三条
- 零新依赖:fastapi / uvicorn 已在 `backend/requirements.txt`

API:

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/runs` | run 列表:run_id / 身份摘要 / 通过率 / 时间 / 是否 baseline |
| GET | `/api/runs/{run_id}` | 单 run 全量 `results.jsonl` + `meta.json` |
| GET | `/api/runs/{run_id}/diff?baseline=<id>` | 跨 run diff(默认 baseline 取 `runs/BASELINE`) |
| GET | `/api/cases/{case_id}/{module}?run=<id>` | 单格详情:prompt / response / L1 / L2 / L3 |
| POST | `/api/runs` | 触发新 run,body `{modules?, cases?, no_cache?, skip_judge?}`,返回 run_id |
| GET | `/api/runs/{run_id}/progress` | 进度轮询(已完成 / 总数 / 当前 case+module) |
| POST | `/api/baseline` | body `{run_id}`,写入 `runs/BASELINE` |

- `POST /api/runs` 用 FastAPI `BackgroundTasks` 起后台任务,立即返回 run_id;前端轮询 `/progress`
- **同时只允许一个 run 在跑**:已有运行中的 run 时返回 409,不并发烧钱

### 2. `backend/evalkit/static/index.html` — vanilla 单页

零构建、零框架、零 CDN(离线可用)。四块:

1. **顶部**:run 选择器(current / baseline 两个下拉)+ 总览条(通过率 / **退化数** / 缓存命中 / 调用数 / 总耗时)+「跑新 run」按钮(带 no-cache / skip-judge 勾选)
   - 两个 run 的 `RunIdentity` 有差异时(如 model 不同)**显式横幅提示**"本次对比跨了 model 变更",避免把环境差异读成质量退化
2. **退化清单**:`regressed` 置顶,朱砂红。每条显示 `case_id / module / 失败判据首条`,点击进详情。空时显示"无退化"
3. **矩阵**:20 行(case)× 8 列(module)色块网格
   - 绿 `#2C5F3F` = pass / 黄 = warn(L3 低分)/ 红 `#C33B3B` = fail / 灰 = error 或 skipped
   - 行头标 case 类别(普通/专旺/从格)+ 季节或 pattern_hint
   - **这块的价值是一眼分辨"某一盘全崩"(整行红)还是"某个模块全崩"(整列红)——两种失败的修法完全不同**:前者多半是 fixture 边界或排盘问题,后者是模板问题
4. **详情抽屉**:点格子展开
   - 左:rendered prompt(可折叠,通常很长)
   - 右:response JSON(语法高亮可选,不强求)
   - 下:L1 / L2 / L3 逐条判据,**每条 failure 显示 S03 要求的证据片段**
   - 与 baseline 的并排 diff(同格在 baseline 的 verdict 与 failures)

**视觉**(遵循 `DESIGN.md`,内部工具不追求精致但不违反设计系统):
- 背景 `#FDFCFA`,卡片 `#EBE3D0`,文字 `#1C1C1C`
- 退化 `#C33B3B` 朱砂,通过 `#2C5F3F` 墨青
- 4pt 圆角,0.5pt hairline `#6B6557 @ 30%` 分隔
- **禁止渐变、禁止阴影、禁止玻璃态**
- 系统字体栈(PingFang SC / Songti SC / SF Pro),**不打包自定义字体、不引 Google Fonts**

### 3. `backend/eval.sh`

对齐既有 `backend/run.sh` 的写法,一键起评测服务(激活 venv + uvicorn + 打印 URL)。

### 4. 首轮基线

1. `python -m evalkit.runner --dry-run` 全量过一遍(排盘 + chart + 渲染 + 链式注入)
2. 真跑 20 盘 × 8 模块 = 160 次调用(首轮无缓存可命中)
3. **人工复核全部 L2 failure**(S03 的「宁可漏报」立场要求):误报 → 回 S03 收紧模式重跑,不要带着噪声进基线
4. 复核 L3 评分合理性(S05 校准的复查)
5. `python -m evalkit.store --set-baseline <run_id>`,提交 `runs/BASELINE`

### 5. CLAUDE.md 守护栏(Q9)

「项目特定约束」下新增一节,对齐既有「prompt 三边一致性」「城市数据库守护栏」的写法:

```
### Prompt 回归守护栏(2026-08-17,evalkit)

- **强制**:动了 `app/ai/prompts.py` 的 M0-M7 模板(`m0_structure` ~ `m7_manual`)任一,
  必须跑 `cd backend && python -m evalkit.runner` 且**无 regression**(退出码 0)才算完成
- 改模板必须同时 bump 对应 `PROMPT_VERSIONS`(老缓存自然失效,同时让 run 身份可辨认)
- 有 regression 的正确处理:回 UI 看退化清单逐条判断——真退化就改模板,
  判据误报就修 `evalkit/checks/`;**禁止**直接改 BASELINE 掩盖退化
- 不接 GitHub Actions(对齐 2026-08-14「本地优先」决定),拦截靠本规则
```

同时更新 `CLAUDE.md` 的「当前阶段」段落,提一句 evalkit 已落地。

### 6. 收尾

`docs/prompt评测机设计决策.md` 的 `Status` 从 `ACCEPTED` 改 `IMPLEMENTED`,补「实施偏差记录」小节(如有)。

## Acceptance criteria

- [ ] `server.py` 起在 `127.0.0.1:8899`,7 个 API 全部可用;docstring 明写"只监听本地 / 无鉴权 / 不进生产镜像"
- [ ] `POST /api/runs` 后台跑 + `/progress` 轮询可用;已有 run 在跑时返回 409
- [ ] `index.html` 四块齐,零外部资源(断网可用)
- [ ] 矩阵 20×8 渲染正确,色块与 `results.jsonl` 的 `verdict` **逐格一致**
- [ ] 点格子能看到 prompt / response / L1L2L3 逐条判据 + 证据片段 + baseline 并排 diff
- [ ] 两 run 身份不同(如 model 变更)时有横幅提示
- [ ] 视觉自查:无渐变、无阴影、色值取自 `DESIGN.md`、未打包字体
- [ ] `eval.sh` 一键起服务
- [ ] **端到端回归验收**(见「测试」)通过
- [ ] 首轮基线跑完,**L2 failure 全部人工复核**,`runs/BASELINE` 进 git
- [ ] `CLAUDE.md` 增补守护栏一节 + 更新「当前阶段」
- [ ] 决策文档 Status 改 `IMPLEMENTED` + 实施偏差记录
- [ ] `pytest backend/tests/` 全绿;`python3 tools/check_prompt_sync.py` PASS(确认本系列未破三边一致性)

## 实现锚点(现状快照 2026-08-17,实施以代码为准)

- `backend/app/main.py` — 生产 app。**本 slice 不改它**,只作为 FastAPI 写法参考(异常 handler / middleware 风格)
- `backend/run.sh` — `eval.sh` 的写法参照
- `backend/requirements.txt` — 确认 fastapi / uvicorn 已在(**零新依赖**)
- `backend/evalkit/store.py`(S04 产出)— `diff_runs()` / `RunIdentity` / BASELINE 读写,server 直接调
- `backend/evalkit/runner.py`(S01/S02/S03/S05 产出)— `POST /api/runs` 调用目标
- `DESIGN.md` — 色板与视觉红线事实源(`#FDFCFA` / `#EBE3D0` / `#C33B3B` / `#2C5F3F` / `#1C1C1C` / 4pt 圆角 / hairline `#6B6557 @ 30%` / 禁渐变 / 不打包字体)
- `CLAUDE.md` — 「prompt 三边一致性」与「城市数据库守护栏」两节是新守护栏的格式范本
- `tools/check_prompt_sync.py` — 收尾回归要跑

## 红线与约束

- **不进生产**:独立 app、只监听 127.0.0.1、不改 `app/main.py`、不进生产镜像
- **零外部资源**:UI 不引 CDN / Google Fonts / 图表库,断网可用
- **视觉先读 `DESIGN.md`**:偏离须用户明确批准
- **禁止改 BASELINE 掩盖退化**:这条写进 CLAUDE.md 守护栏。基线是用来被打脸的,不是用来被调整的
- **基线质量优先于基线速度**:L2 有误报就先修判据再定基线。带噪声的基线会训练出"习惯性忽略红色"的坏习惯,那时整套工具的价值归零
- **不并发跑 run**:同时只允许一个,避免重复烧钱和结果互相覆盖
- **不擅自加依赖**:vanilla HTML/CSS/JS,无构建步骤

## 测试

- `pytest backend/tests/` 全绿
- `python3 tools/check_prompt_sync.py` PASS
- 新增 `backend/tests/test_evalkit_server.py`(用 `httpx` + FastAPI TestClient,**零 API 调用**):7 个 GET 端点返回结构正确;`POST /api/runs` 在已有 run 运行时返回 409;`POST /api/baseline` 写入正确
- **手工 UI 验收**:矩阵逐格比对 `results.jsonl`;点开三格看详情完整;断网刷新页面仍可用

**端到端回归验收(整个系列的存在理由,必须真验一次)**:

1. 记下当前基线
2. 故意在某个模块模板里删掉一条约束(如 M2 的 `switch_actions` 必须恰好 3 条)+ bump 该模块 `PROMPT_VERSIONS`
3. 重跑
4. 确认:① UI 首屏红色列出退化的 case ② CLI 退出码 = 1 ③ 缓存生效——只有该模块及其下游重新调 API
5. 撤销改动 + 恢复版本号,重跑确认回到无退化(退出码 0)
6. 全过程记入交付报告
