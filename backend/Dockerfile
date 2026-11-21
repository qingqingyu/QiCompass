# QiCompass API 生产镜像(S2,2026-11-18;docs/后端部署设计决策.md §2.1/§2.3)
#
# - python:3.12-slim 对齐开发 venv(3.12.x);tzdata 是硬约束(C8:启动自检
#   _ensure_tzdata_available 要求,slim 镜像默认不带)
# - 只进 app/ + requirements.txt + run.sh:evalkit / spikes / tests 不进镜像
#   (对齐 §3「evalkit 与 8899 UI 不进生产镜像」;由 .dockerignore 兜底)
# - Apple Root CA 证书不入 git(app/entitlement/certs 仅 .gitkeep),生产由
#   compose 从宿主 ./certs 挂载(ro);env 配齐而证书缺失 → 启动 fail-fast,
#   不会静默降级
# - 容器内绑 0.0.0.0 是正确的(§2.2);对公网暴露由 compose 不 publish 8000
#   兜住,唯一入口 Caddy :443
# - 跨架构(2026-11-18 S2 review):Apple Silicon Mac 上 docker build 默认产出
#   arm64 镜像,amd64 服务器拉起即 exec format error——Mac 构建须
#   docker buildx build --platform linux/amd64(按服务器实机架构),或走
#   rsync 源码到服务器 build 的天然同构路径(§5)
# - 非 root 运行(2026-11-21 推前 review 可选项落地):固定 uid/gid 10001
#   (避开常见宿主首位用户 uid 1000,防意外同 id 继承宿主写权限面)。
#   ./data bind mount 属主是宿主用户,非 root 后容器内首写会 EACCES——
#   部署时宿主侧 `sudo chown -R 10001:10001 ./data`,run.sh 启动自检
#   data/ 可写并带该指引 fail-fast(见 run.sh)。

FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY run.sh ./
RUN chmod +x run.sh \
    && groupadd -g 10001 app \
    && useradd -u 10001 -g 10001 -m app \
    && chown -R app:app /app

USER app

EXPOSE 8000

CMD ["./run.sh"]
