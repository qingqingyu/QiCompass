# QiCompass 后端(FastAPI)

排盘 / 合盘 / 每日运势 API。`lunar_python` 同步 CPU-bound,路由层用
`run_in_threadpool` 包;API key 只在后端,不进客户端。

## 部署备忘

- **tzdata 必须可用**(S02 时区解释依赖 stdlib `zoneinfo`):macOS/Linux 开发
  环境自带零动作;**Alpine 容器需 `apk add tzdata`**,否则历史夏令时规则
  (1986-91 中国夏令时等)缺失,启动自检会直接失败(`app/main.py` 探针)。
- 运行:`./run.sh`;测试:`python3 -m pytest tests/ -q`(根目录 `pytest.ini`)。
