"""Common helper: capture git sha + working-tree status for baseline JSON.

Pattern reference: optimization-baseline-must-include-existing-mitigations.md
"""

from __future__ import annotations

import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def _sh(repo: str, *args: str) -> str:
    return subprocess.check_output(["git", "-C", repo, *args], text=True).strip()


def git_meta(repo_path: str | Path = ".") -> dict:
    repo = str(repo_path)
    sha = _sh(repo, "rev-parse", "HEAD")
    branch = _sh(repo, "rev-parse", "--abbrev-ref", "HEAD")
    status = _sh(repo, "status", "-s")
    return {
        "git_sha": sha,
        "git_branch": branch,
        "git_status_clean": status == "",
        "git_status_raw": status if status else None,
        "captured_at": datetime.now(timezone.utc).isoformat(),
    }


def host_meta() -> dict:
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    }
