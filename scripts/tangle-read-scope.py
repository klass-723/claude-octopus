#!/usr/bin/env python3
"""Validate declared Tangle read context. This is not an OS filesystem sandbox."""
from __future__ import annotations
import os
from pathlib import Path
import re
import sys

SAFE_PATH = re.compile(r"[A-Za-z0-9_.@%+/-]+\Z")
SENSITIVE_DIRS = {".git", ".ssh", ".gnupg", ".aws", ".azure", ".kube", "harness-auth", "credentials", "secrets"}
SENSITIVE_FILES = {
    "auth.json", "auth-profiles.json", "credentials.json", "credentials.yml",
    "credentials.yaml", "secrets.json", "secrets.yaml", "secrets.yml",
    "tokens.json", "cookies.json", "cookies.txt",
    ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
}

def sensitive(path: Path) -> bool:
    parts = tuple(part.lower() for part in path.parts)
    if any(part in SENSITIVE_DIRS or part == ".env" or part.startswith(".env.") for part in parts):
        return True
    # Hidden applications commonly keep credentials in a self-named JSON file,
    # such as .tool/tool.json. This stays generic rather than coupling the policy
    # to any particular integration.
    if any(
        part.startswith(".") and parts[-1] == f"{part[1:]}.json"
        for part in parts[:-1]
    ):
        return True
    if path.name.lower() in SENSITIVE_FILES:
        return True
    if path.suffix.lower() in {".key", ".p12", ".pfx", ".env"}:
        return True
    return any(parts[i:i + 2] in {(".docker", "config.json"), (".claude-octopus", "config")} for i in range(len(parts) - 1))

def safe_syntax(value: str) -> bool:
    if not value or not SAFE_PATH.fullmatch(value):
        return False
    normalized = value[2:] if value.startswith("./") else value
    return normalized not in {"", ".", "..", "/"} and not any(part in {".", ".."} for part in normalized.split("/"))

def within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents

def allowed(repo: Path, scope: str, mode: str, entries: str) -> bool:
    if mode not in {"strict", "contextual"} or not safe_syntax(scope):
        return False
    declared = Path(scope)
    if mode == "strict" and declared.is_absolute():
        return False
    canonical_repo = repo.resolve(strict=True)
    if not canonical_repo.is_dir():
        return False
    candidate = declared if declared.is_absolute() else canonical_repo / declared
    canonical = candidate.resolve(strict=False)
    if sensitive(candidate) or sensitive(canonical):
        return False
    # Missing repository paths may be created by an earlier subtask. Resolve
    # existing symlink ancestors even for such paths; never authorize escapes.
    if within(canonical, canonical_repo):
        return not canonical.exists() or canonical.is_file() or canonical.is_dir()
    if mode != "contextual" or not canonical.exists():
        return False
    if not (canonical.is_file() or canonical.is_dir()):
        return False
    for value in entries.splitlines():
        if not safe_syntax(value) or not Path(value).is_absolute():
            continue
        root = Path(value)
        if sensitive(root):
            continue
        try:
            resolved_root = root.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if resolved_root == Path(resolved_root.anchor) or sensitive(resolved_root):
            continue
        # A file authorizes that file only, never its parent directory.
        if resolved_root.is_file() and canonical == resolved_root:
            return True
        if resolved_root.is_dir() and within(canonical, resolved_root):
            return True
    return False

def main() -> int:
    if len(sys.argv) != 4:
        return 64
    try:
        ok = allowed(Path(sys.argv[1]), sys.argv[2], sys.argv[3], os.environ.get("OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS", ""))
        return 0 if ok else 1
    except (OSError, RuntimeError, ValueError):
        return 1

if __name__ == "__main__":
    sys.exit(main())
