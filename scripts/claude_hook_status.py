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

"working" and "done" are upgraded to "failed" when the most recent tool result
in the session's transcript is an error — see last_tool_errored() for why that
has to be read out of the transcript rather than taken from the hook payload.
"""
import fcntl
import json
import os
import sys
import time

STATUS_FILE = os.path.expanduser("~/.claude/connor-pet-status.json")
LOCK_FILE = STATUS_FILE + ".lock"

# How much of the transcript's tail to inspect for a failed tool. Transcripts
# reach tens of MB (a 31MB session was observed), so this is seeked from the
# end rather than read from the top.
TRANSCRIPT_TAIL_BYTES = 256 * 1024
TRANSCRIPT_TAIL_LINES = 80


def last_tool_errored(transcript_path):
    """True when the most recent tool result in the transcript is an error.

    Why read the transcript at all: the PostToolUse hook does **not** fire when
    a tool fails (verified against a live session), so a failure never reaches
    us as a hook event. It does land in the transcript, as a tool_result block
    with "is_error": true — and the hook payload hands us transcript_path, so
    the tail is right there.

    Only the *last* tool result counts. A tool that failed and was then retried
    successfully is not a failure the user needs to see; a turn whose final
    tool errored is.
    """
    if not transcript_path or not os.path.isfile(transcript_path):
        return False
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - TRANSCRIPT_TAIL_BYTES))
            # The first line after an arbitrary seek is usually a partial
            # record; dropping it is why the slice starts at 1.
            lines = f.read().splitlines()[1:][-TRANSCRIPT_TAIL_LINES:]
    except OSError:
        return False

    for raw in reversed(lines):
        try:
            record = json.loads(raw)
        except Exception:
            continue
        content = (record.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in reversed(content):
            if isinstance(block, dict) and block.get("type") == "tool_result":
                return bool(block.get("is_error"))
    return False


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
                state = action
                if action in ("working", "done") and last_tool_errored(payload.get("transcript_path")):
                    state = "failed"
                doc["entries"][session_id] = {
                    "state": state,
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
