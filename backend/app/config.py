"""应用全局常量。"""

# lunar_python 版本(与 requirements.txt 锁定一致)
LUNAR_PYTHON_VERSION = "1.4.8"

# 当前 schema 版本(ChartSnapshot D1)
SCHEMA_VERSION = 1

# 标准时区中心经度(东八区 = 120°E)
# 真太阳时偏移 = EoT + (经度 - 时区中心经度) × 4分钟/度
DEFAULT_TIMEZONE_CENTRAL_LONGITUDE = 120.0

# API 模型标识
MODEL_ID = "bazi-calculate-v1"
