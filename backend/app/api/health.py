"""GET /api/health。"""

from fastapi import APIRouter, Request, Response

from ..config import LUNAR_PYTHON_VERSION, MODEL_ID

router = APIRouter()


@router.get("/api/health")
def health(request: Request, response: Response) -> dict:
    """返回运行中实际 AI client 身份;禁止 HTTP 缓存避免切换后读旧值。"""
    ai_client = request.app.state.ai_client
    response.headers["Cache-Control"] = "no-store"
    return {
        "status": "ok",
        "lunar_python_version": LUNAR_PYTHON_VERSION,
        "model": MODEL_ID,
        "ai_provider": ai_client.provider,
        "ai_model": ai_client.model,
    }
