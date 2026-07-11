"""GET /api/health"""

from fastapi import APIRouter

from ..config import LUNAR_PYTHON_VERSION, MODEL_ID

router = APIRouter()


@router.get("/api/health")
def health() -> dict:
    return {
        "status": "ok",
        "lunar_python_version": LUNAR_PYTHON_VERSION,
        "model": MODEL_ID,
    }
