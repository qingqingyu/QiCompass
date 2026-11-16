# QiCompass / KnowFate 后端生产镜像。
# 构建与运行见 deploy/README.md;设计依据见 docs/后端部署设计决策.md。
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# tzdata:app/main.py 启动自检要求系统时区库(历史夏令时规则),缺失即拒绝启动。
RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY run.sh ./

# 非 root 运行;uid 固定为 10001,宿主机数据目录与 .env 按此 uid 授权
# (deploy/server-deploy.sh 负责 chown)。
RUN useradd --uid 10001 --no-create-home qc \
    && mkdir /data \
    && chown qc:qc /data
USER qc

# 依赖装在系统 Python(无 .venv);数据库落挂载卷。
# .env 由 compose 只读挂载到 /app/.env,run.sh 用 bash source 读取——
# 与 Mac 开发环境同一套解析口径。
ENV UVICORN_BIN=uvicorn \
    QICOMPASS_DB_PATH=/data/qicompass.db

EXPOSE 8000
CMD ["./run.sh"]
