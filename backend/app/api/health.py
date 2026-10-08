"""GET /api/health。"""

from fastapi import APIRouter, Request, Response

from ..ai.prompts import PROMPT_VERSIONS
from ..config import LUNAR_PYTHON_VERSION, MODEL_ID

router = APIRouter()


@router.get("/api/health")
def health(request: Request, response: Response) -> dict:
    """返回运行中实际 AI client 身份;禁止 HTTP 缓存避免切换后读旧值。

    prompt_versions(2026-10-08 外评 #4):各 module 当前 PROMPT_VERSIONS 快照。
    iOS 读本地解读缓存前强校验 health(ADR-0009),顺带取得版本表——本地行
    只认服务端当前版本,封掉「prompt bump 只失效后端缓存,客户端 24h 内
    旧版行照常命中并写进新合盘快照」的客户端失防窗口。
    """
    ai_client = request.app.state.ai_client
    response.headers["Cache-Control"] = "no-store"
    return {
        "status": "ok",
        "lunar_python_version": LUNAR_PYTHON_VERSION,
        "model": MODEL_ID,
        "ai_provider": ai_client.provider,
        "ai_model": ai_client.model,
        "prompt_versions": dict(PROMPT_VERSIONS),
    }
