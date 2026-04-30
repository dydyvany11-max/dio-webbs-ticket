from typing import Any, override

import contextvars
import json
import logging
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from starlette.middleware.base import BaseHTTPMiddleware

request_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests handled by the application.",
    ["method", "path", "status"],
)
HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds.",
    ["method", "path"],
)
HTTP_REQUESTS_IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "Number of in-progress HTTP requests.",
    ["method"],
)
logger = logging.getLogger(__name__)


class RequestIdFilter(logging.Filter):
    @override
    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = request_id_ctx.get()
        return True


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        log_data: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": getattr(record, "request_id", "-"),
        }

        if record.exc_info:
            log_data["exception"] = self.formatException(record.exc_info)

        return json.dumps(log_data, ensure_ascii=False)


class MetricsMiddleware(BaseHTTPMiddleware):
    @override
    async def dispatch(self, request: Request, call_next):  # type: ignore[override]
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        token = request_id_ctx.set(request_id)

        method = request.method
        path = request.url.path
        HTTP_REQUESTS_IN_PROGRESS.labels(method=method).inc()
        start = time.perf_counter()

        try:
            response = await call_next(request)
            status_code = response.status_code
        except Exception:
            status_code = 500
            logger.exception("Unhandled exception in request %s %s", method, path)
            raise
        finally:
            duration = time.perf_counter() - start
            route = request.scope.get("route")
            if route is not None and hasattr(route, "path"):
                path = route.path

            HTTP_REQUESTS_TOTAL.labels(method=method, path=path, status=str(status_code)).inc()
            HTTP_REQUEST_DURATION_SECONDS.labels(method=method, path=path).observe(duration)
            HTTP_REQUESTS_IN_PROGRESS.labels(method=method).dec()
            request_id_ctx.reset(token)

        response.headers["X-Request-ID"] = request_id
        return response


def configure_logging(log_level: str = "INFO") -> None:
    root_logger = logging.getLogger()
    root_logger.setLevel(log_level.upper())
    root_logger.handlers.clear()
    root_logger.filters.clear()

    log_filter = RequestIdFilter()
    formatter = JsonFormatter()

    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    stream_handler.addFilter(log_filter)
    root_logger.addHandler(stream_handler)

    logs_dir = Path(__file__).resolve().parents[2] / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    file_handler = logging.FileHandler(logs_dir / "backend.log", encoding="utf-8")
    file_handler.setFormatter(formatter)
    file_handler.addFilter(log_filter)
    root_logger.addHandler(file_handler)


def setup_metrics(app: FastAPI) -> None:
    app.add_middleware(MetricsMiddleware)

    @app.get("/metrics", include_in_schema=False)
    async def metrics() -> Response:
        return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
