import logging
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import uvicorn
from fastapi import APIRouter, FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from redis.exceptions import RedisError
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from src.core.database import engine
from src.core.observability import configure_logging, setup_metrics
from src.core.redis import redis_client
from src.core.settings import settings
from src.crm.router import router as counterparty_router
from src.iam.routers import router as iam_router
from src.media.router import router as media_router
from src.proofreading.router import router as proofreading_router
from src.shared.domain.exceptions import AppError
from src.shared.utils.cli import run_cli_command
from src.tickets.routers import router as tickets_router

configure_logging()

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await redis_client.ping()
    await run_cli_command(sys.executable, "-m", "alembic", "upgrade", "head")
    await run_cli_command(sys.executable, "-m", "cli", "create-first-admin")
    await run_cli_command(sys.executable, "-m", "cli", "init-s3-storage")
    yield


app = FastAPI(
    title="Ticket management system",
    description="REST API тикет-системы компании **ДИО-Консалт**",
    version="0.1.0",
    lifespan=lifespan,
)
setup_metrics(app)

router = APIRouter(prefix="/api/v1")

router.include_router(iam_router)
router.include_router(counterparty_router)
router.include_router(media_router)
router.include_router(tickets_router)
router.include_router(proofreading_router)

app.include_router(router)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health", include_in_schema=False)
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/ready", include_in_schema=False)
async def ready() -> JSONResponse:
    checks = {"postgres": False, "redis": False}

    try:
        async with engine.connect() as connection:
            await connection.execute(text("SELECT 1"))
        checks["postgres"] = True
    except SQLAlchemyError:
        checks["postgres"] = False

    try:
        await redis_client.ping()
        checks["redis"] = True
    except RedisError:
        checks["redis"] = False

    is_ready = all(checks.values())
    http_status = status.HTTP_200_OK if is_ready else status.HTTP_503_SERVICE_UNAVAILABLE
    return JSONResponse(
        status_code=http_status,
        content={
            "status": "ready" if is_ready else "not_ready",
            "checks": checks,
        },
    )


@app.exception_handler(ValueError)
def value_exception_handler(request: Request, exc: ValueError) -> JSONResponse:  # noqa: ARG001
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content={
            "error": {
                "code": "VALIDATION_ERROR",
                "message": str(exc),
                "status": status.HTTP_400_BAD_REQUEST,
                "details": {},
            }
        }
    )


@app.exception_handler(AppError)
def app_exception_handler(request: Request, exc: AppError) -> JSONResponse:  # noqa: ARG001
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "code": exc.error_code,
                "message": exc.message,
                "public_message": exc.public_message,
                "status": exc.status_code,
                "details": exc.details,
            }
        }
    )


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=settings.app.port)  # noqa: S104
