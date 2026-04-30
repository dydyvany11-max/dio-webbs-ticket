from __future__ import annotations

import os
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

BACKUP_DIR = Path(os.getenv("BACKUP_DIR", "/backups/last"))
MAX_AGE_SECONDS = int(os.getenv("MAX_AGE_SECONDS", "691200"))  # 8 days by default
PORT = int(os.getenv("PORT", "9105"))


def get_latest_backup_mtime() -> float | None:
    if not BACKUP_DIR.exists():
        return None

    candidates = sorted(
        [
            path
            for path in BACKUP_DIR.iterdir()
            if path.is_file() and (path.name.endswith(".sql") or path.name.endswith(".sql.gz"))
        ],
        key=lambda path: path.stat().st_mtime,
    )
    if not candidates:
        return None
    return candidates[-1].stat().st_mtime


def build_metrics() -> str:
    now = time.time()
    mtime = get_latest_backup_mtime()
    if mtime is None:
        age = float("inf")
        fresh = 0
        last_timestamp = 0
    else:
        age = max(0.0, now - mtime)
        fresh = 1 if age <= MAX_AGE_SECONDS else 0
        last_timestamp = int(mtime)

    generated_at = datetime.now(UTC).isoformat()
    metrics = [
        "# HELP postgres_backup_age_seconds Age of latest PostgreSQL backup in seconds.",
        "# TYPE postgres_backup_age_seconds gauge",
        f"postgres_backup_age_seconds {age}",
        "# HELP postgres_backup_fresh 1 if latest backup is fresh, 0 otherwise.",
        "# TYPE postgres_backup_fresh gauge",
        f"postgres_backup_fresh {fresh}",
        "# HELP postgres_backup_last_timestamp_seconds Unix timestamp of latest backup file.",
        "# TYPE postgres_backup_last_timestamp_seconds gauge",
        f"postgres_backup_last_timestamp_seconds {last_timestamp}",
        "# HELP backup_exporter_generated_at Timestamp when metrics were generated.",
        "# TYPE backup_exporter_generated_at gauge",
        f"backup_exporter_generated_at{{iso=\"{generated_at}\"}} 1",
        "",
    ]
    return "\n".join(metrics)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return

        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        body = build_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
