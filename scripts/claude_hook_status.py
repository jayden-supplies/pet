#!/usr/bin/env python3
"""
Claude Code hook handler for connor-pet. Wired into ~/.claude/settings.json
(see README.md "Claude Code 훅으로 얼음/헤롱헤롱까지 보기") on UserPromptSubmit/
PreToolUse/Notification/Stop/SessionEnd. Each invocation reads the hook's JSON
payload from stdin, extracts session_id/cwd, and does an atomic read-modify-
write of ~/.claude/connor-pet-status.json — a file shaped exactly like Orca's
last-status.json (see ClaudeCodeStatusWatcher.swift, which polls it) so the
same entries/state parsing works for both sources:

  {"version": 2, "entries": {"<session_id>": {"state": ..., "worktreeId": ...,
  "receivedAt": ...}}}

Usage: python3 claude_hook_status.py <working|blocked|done|remove>
(state comes from argv[1]; session_id/cwd come from the hook's stdin JSON)
"""
import fcntl
import json
import os
import sys
import time

STATUS_FILE = os.path.expanduser("~/.claude/connor-pet-status.json")
LOCK_FILE = STATUS_FILE + ".lock"


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("working", "blocked", "done", "remove"):
        print("usage: claude_hook_status.py <working|blocked|done|remove>", file=sys.stderr)
        return 1

    action = sys.argv[1]
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    session_id = payload.get("session_id")
    if not session_id:
        return 0  # nothing to key the entry by — silently no-op rather than fail the hook

    cwd = payload.get("cwd", "")

    # Why: multiple Claude Code sessions can fire hooks around the same moment
    # (e.g. two turns finishing near-simultaneously). Without a lock, a plain
    # read-modify-write here is a classic lost-update race — the second
    # writer's atomic replace can clobber the first writer's entry because it
    # read the file before the first writer's replace landed.
    os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            try:
                with open(STATUS_FILE) as f:
                    doc = json.load(f)
            except Exception:
                doc = {"version": 2, "entries": {}}
            if not isinstance(doc.get("entries"), dict):
                doc["entries"] = {}

            if action == "remove":
                doc["entries"].pop(session_id, None)
            else:
                doc["entries"][session_id] = {
                    "state": action,
                    "worktreeId": cwd,
                    "receivedAt": int(time.time() * 1000),
                }

            tmp_path = STATUS_FILE + f".tmp.{os.getpid()}"
            with open(tmp_path, "w") as f:
                json.dump(doc, f)
            os.replace(tmp_path, STATUS_FILE)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
    return 0


if __name__ == "__main__":
    sys.exit(main())
