"""Logging setup for the Aegis classifier.

Framework decision (Phase 1): loguru.
Rationale: simpler API than stdlib `logging`; structured stderr format
with timestamp/level/module out of the box; level filtering is one line.
The cross-cutting concerns in PROJECT_PLAN.md tentatively recommended loguru
and allowed Phase 1 to swap to stdlib `logging`. We keep loguru.

All classifier modules import via:
    from classifier.log import setup_logger
    logger = setup_logger()

Reading the AEGIS_LOG_LEVEL env var (defaults to "info") lets users bump
verbosity without editing code. Logs always go to stderr -- stdout is
reserved for the Claude Code permission decision JSON.
"""

from __future__ import annotations

import os
import sys

from loguru import logger as _logger


def setup_logger(level: str | None = None):
    """Configure the loguru logger to write structured records to stderr.

    Idempotent: removing all handlers before re-adding ensures repeated calls
    do not duplicate output.

    Args:
        level: Optional log level override ("trace"|"debug"|"info"|"warning"|
            "error"|"critical"). Defaults to AEGIS_LOG_LEVEL env var or "info".

    Returns:
        The configured loguru logger.
    """
    resolved_level = (level or os.environ.get("AEGIS_LOG_LEVEL") or "info").upper()
    _logger.remove()
    _logger.add(
        sys.stderr,
        level=resolved_level,
        format="[{time:YYYY-MM-DD HH:mm:ss}] [{level}] [{name}] {message}",
        enqueue=False,
    )
    return _logger
