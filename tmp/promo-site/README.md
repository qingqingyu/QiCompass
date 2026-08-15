# QiCompass Promo Site(内部宣传物料生成工具)

> **位置**:`tmp/promo-site/`(已被 `.gitignore` 忽略,不进 git)
> **目的**:为开发者本人(我)提供本地运行的八字解析网页物料生成工具,用于在 Reddit / X 等平台宣传 QiCompass。
> **不做**:多用户 / 权限 / 公开部署 / 持久化缓存。

---

## 它能做什么

复用 QiCompass `backend/` 的 engine + ai client 模块,**不走 HTTP 调用**:

- **深度解析**(bazi_deep_paid)— 5 章,200-300 字/章
- **合盘**(compatibility_paid)— 4 章 + 四项定性评估 + 3 年流年同步
- **每日运势**(daily_fortune)— 50-80 字短解读 + 黄历宜忌 + 12 时辰

每个结果页支持:
- 网页在线展示(markdown 渲染)
- **截图模式**(隐藏 nav/footer + 锁宽 1080 + 显示水印/引导)
- **导出 PNG**(html2canvas,自动下载)

---

## 启动

### 前置条件

```bash
# 1. 安装依赖(首次)
cd tmp/promo-site
pip install -r requirements.txt

# 2. 设置 API key(两种方式)
#    a) 环境变量:export ANTHROPIC_API_KEY=sk-ant-...(或 OPENAI_API_KEY + AI_PROVIDER=openai)
#    b) 网页填:打开任一模块表单 → 「⚙ AI 配置」→ 填 provider/key/base_url/model
#       → 「🔌 测试连接」验证 → 「💾 保存配置」存本机 localStorage
```

### 启动命令

```bash
cd tmp/promo-site
uvicorn main:app --reload --port 8765
# 浏览器打开 http://localhost:8765
```

**端口 8765**(避开 backend 的 8000,允许两者同时跑)。

**不需要同时启动 backend**。promo-site 通过 `sys.path.insert` 直接 import backend 模块,完全独立。

**Anthropic 中转**:provider=Anthropic + 自定义 Base URL(如 z.ai `https://api.z.ai/api/anthropic`)由
`AnthropicClient(base_url=...)` 支持(2026-08-13 加,`/v1/messages` 由 client 拼接);
「测试连接」探针与正式生成走同一 URL 口径。

**全量城市选择**(2026-08-15):出生地不再是 52 城下拉,改为全球 23.5 万聚落 autocomplete
(GeoNames cities500,含中文别名;中国覆盖到镇/乡级,自然村不在数据源内)。

- 数据构建:`tools/build_city_db.py`(读 cities500.txt → `data/cities.db`,254k 行/25MB;
  重复跑即更新,数据源 CC-BY 4.0)
- 接口:`GET /geo/search?q=`(中文/拼音/英模糊,人口优先 top20);
  `GET /geo/tz_offset?tz=&dt=`(zoneinfo 按**出生时刻**算偏移,含 1986-1991 中国夏令时)
- 前端:`form.js` autocomplete + 选中自动填 longitude/city_tz/tz_offset;
  出生日期/时间/时辰变化都会重算偏移(夏令时边界依赖具体日期)
- 连接策略:每请求独立只读 sqlite 连接(全局连接跨线程会 ProgrammingError,踩过)
- 静态资源版本已 bump `?v=20260815a`;uvicorn 加了 `--timeout-keep-alive 5`
  减少浏览器 keep-alive 卡住 reload 的问题

### 不需要的 env

- `JWT_SECRET_KEY` — promo-site 自动注入 dev 占位符(promo 不用 JWT)
- `QICOMPASS_DB_PATH` — promo 不用 InterpretationCache
- `APP_STORE_*` — promo 不用付费系统

---

## 复用关系

```
tmp/promo-site/main.py
    ↓ sys.path.insert(0, '../../../backend')
    ↓ 直接 import
backend/app/
    ├─ engine/bazi_engine.py:55    BaziEngine.calculate()
    ├─ engine/compatibility.py:345 compute_compatibility()
    ├─ engine/daily_fortune.py:63  compute_daily_fortune()
    ├─ ai/client.py:27             create_ai_client()
    ├─ ai/prompts.py:719           render_prompt()
    └─ ai/forbidden_words.py:43    validate_interpretation()
                             ↑ 强制走(promo 物料发公开平台必过禁词扫描)

promo-site 本地新增:
tmp/promo-site/promo_prompts.py  render_prompt_with_length()
    └─ 篇幅档(2026-08-13):表单选「加长版」时,把 backend 模板的
       「写作要求」块整体换成 promo 长文版(每章 1000-1500 字 / 每日 400-600 字),
       HEADER(命主/四柱/评估数据)原样保留;「App 标准」= backend 原样。
       同时加长版调 AI 用 max_tokens=24576 + timeout=420s
       (App 路径仍是 config 默认 1024 / 90s,backend prompts.py 未动 —
       App Medium voice 是产品决策,只在 promo 调用侧放宽)。
    └─ 十神结构章(2026-08-14):深度解析加长版固定第一章为「十神结构与命局主线」
       (十神主线三层 / A→B→A 核心循环 / 结构命名,承接 v1 设计文档 M0 叙事),
       付费 6 章、免费 3 章;数据用 HEADER 已注入的四柱十神+藏干,App 无此章。

backend/spikes/prompt_validation/run_spike.py:75
    └─ build_bazi_deep_context()   ← promo-site context_builder.py 复用
                                     (避免 38 字段映射重复,已 20 盘验证)
```

**关键规避**:promo-site **绝不** import `backend.app.config`,因为 `config.py:127` 的 `JWT_SECRET_KEY` 在 import 时强制检查会阻塞启动。所有 env 由 promo-site 自己读。

---

## 截图工作流(发 Reddit 用)

### Step 1: 生成解析

打开任一模块表单 → 填出生信息 → 选篇幅档(默认「加长版」,宣传长文每章 1000-1500 字;「App 标准」= iOS 实际输出,用于对比截图)→ 点"生成" → 加长版等 1-5 分钟 → 看到结果页。

### Step 2: 切换截图模式

结果页中间有 **截图工具栏**:

```
┌────────────────────────────────────────────┐
│ 截图模式: [切换截图模式] [导出 PNG]        │
│ 导出 PNG 前先点"切换截图模式",锁宽 1080... │
└────────────────────────────────────────────┘
```

点 **切换截图模式** 按钮:
- 隐藏顶部 nav / 底部 footer / 工具栏自身
- 内容锁宽 1080px
- 显示顶部小标题(如"QiCompass · 深度解析")
- 显示底部水印(`QiCompass · 玄机问道  qicompass.app`)
- 显示底部引导(`下载 iOS App 搜索「QiCompass」获取完整命理解析`,朱砂色)

### Step 3: 导出 PNG

点 **导出 PNG** 按钮:
- html2canvas 1.4.1 走**本地 vendor**(`static/vendor/`,2026-08-13 去 CDN 化——jsdelivr 国内不稳)
- 截图 `.capture-target` 元素(包含命盘 + AI 解读 + 水印 + 引导)
- 等待 `document.fonts.ready`(Songti SC 渲染到 canvas)
- 自动下载:`qicompass_<module>_<timestamp>.png`
  - 例:`qicompass_bazi_20260813_153012.png`
- 工具栏下方显示 **✓ 状态 + 「点这里查看 / 另存」链接**(浏览器下载目录不明显时用)

### Step 4: 发 Reddit

直接把 PNG 拖到 Reddit 帖子编辑器。1080px 宽适合:
- Reddit 主帖图(1080×1350 4:5 卡片 — 自行裁剪或截图前缩小窗口)
- Reddit 长图(1080×auto — 默认就是这个)

---

## 文件结构

```
tmp/promo-site/
├── README.md                    # 本文档
├── requirements.txt             # fastapi + uvicorn + jinja2 + markdown + python-multipart
├── .gitignore                   # *(双保险,顶层 .gitignore 已加 tmp/)
├── main.py                      # FastAPI app + sys.path 注入 + JWT 占位符 + 三模块路由
├── context_builder.py           # build_bazi/compat/daily_context(复用 spike)
├── templates/
│   ├── base.html                # 公共骨架
│   ├── index.html               # 首页三模块入口
│   ├── bazi_form.html           # 深度解析输入
│   ├── bazi_result.html         # 深度解析结果 + 截图工具栏
│   ├── compat_form.html         # 合盘输入(两人)
│   ├── compat_result.html       # 合盘结果 + 截图工具栏
│   ├── daily_form.html          # 每日运势输入
│   ├── daily_result.html        # 每日运势结果 + 截图工具栏
│   └── partials/
│       └── export_toolbar.html  # 共用截图工具栏
└── static/
    ├── styles.css               # DESIGN.md token + 三模块专属样式 + 截图模式样式
    ├── markdown.css             # AI markdown 输出样式
    ├── export.js                # html2canvas(本地 vendor)加载 + 截图模式 + PNG 导出 + 状态反馈
    └── vendor/
        └── html2canvas.min.js   # 1.4.1,MIT(2026-08-13 vendor,不再走 CDN)

**静态资源缓存**:模板引用带 `?v=` 版本号(如 `export.js?v=20260813b`),改 JS/CSS 后同步 bump,
否则浏览器用旧缓存(2026-08-13 踩过:改了 export.js 但浏览器跑旧版,以为修复无效)。

**v1 页 markdown**:v1 链 module 文本(LLM 输出)含 `**粗体**` 等语法,模板走 `{{ value | md }}`
过滤器(main.py `_md_filter`)渲染成 HTML;字符串列表项同样处理;JSON dump 字段保持原样。
```

---

## 视觉(对齐 DESIGN.md)

| 元素 | 值 |
|---|---|
| 主背景 | `#FDFCFA` 极浅暖白 |
| 卡片底 | `#EBE3D0` 浅宣 |
| 文字 | `#1C1C1C` 浓墨 |
| 主 CTA | `#C33B3B` 朱砂 |
| 吉神 | `#2C5F3F` 墨青 |
| 凶神 | `#1D3A5F` 黛蓝 |
| 字体 | Songti SC(标题/干支)+ PingFang SC(正文)+ SF Pro Text tabular-nums(数字) |
| 间距 | 8pt 基准网格 |
| 分隔 | 0.5pt hairline `#6B6557 @ 30%` |
| **禁止** | 阴影 / 渐变 / 玻璃态 / 黑金命理套路 |

---

## 错误处理

| 场景 | HTTP | 显示 |
|---|---|---|
| 表单字段缺失 | 400 | `error-box` 显示"表单解析失败" |
| 排盘失败(engine 异常) | 500 | `error-box` 显示"排盘失败:..." |
| AI 调用失败(API key 缺失 / 网络) | 503 | `error-box` 显示"AI 调用失败:..." |
| 禁词命中 | 422 | `error-box` 显示"禁词拦截:..."(promo 物料发公开平台必过) |

所有错误显式传播(对齐 CLAUDE.md "错误显式传播"),不静默吞,不白屏。

---

## 不做的事

- **不复用 InterpretationCache** — promo 是"生成一次截图保存"工作流,缓存命中反而脏
- **不部署到公网** — localhost only
- **不做用户系统** — 无登录 / 无多用户
- **不做完整 markdown 净化** — AI 输出已过 forbidden_words + LLM 模板约束,暂不引入 nh3/bleach(若后续要严,加 nh3 ~1MB pure Python)
