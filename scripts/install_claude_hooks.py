#!/usr/bin/env python3
"""
Installs the connor-pet Claude Code hooks into ~/.claude/settings.json (see
README.md "Claude Code 훅으로 얼음/헤롱헤롱까지 보기"). This is the scripted
equivalent of pasting the JSON snippet in by hand — it merges into whatever
hooks are already there instead of clobbering them, resolves the path to
`claude_hook_status.py` from this script's own location (so it works
regardless of where the repo is cloned), and is safe to re-run (won't
duplicate entries it already installed).

This touches a *global* file that affects every Claude Code session on this
machine, not just this project — it does nothing until you run it yourself.

Usage:
  python3 scripts/install_claude_hooks.py            # install
  python3 scripts/install_claude_hooks.py --uninstall # remove connor-pet's entries
"""
import json
import os
import shutil
import sys
import time

SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
HERE = os.path.dirname(os.path.abspath(__file__))
HOOK_SCRIPT = os.path.join(HERE, "claude_hook_status.py")

# event -> state argument passed to claude_hook_status.py
HOOK_EVENTS = {
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PermissionRequest": "blocked",
    "Notification": "blocked",
    "Stop": "done",
    "SessionEnd": "remove",
}


def command_for(state):
    return f"python3 {HOOK_SCRIPT} {state}"


def is_connor_pet_entry(hook):
    return (
        hook.get("type") == "command"
        and isinstance(hook.get("command"), str)
        and "claude_hook_status.py" in hook["command"]
    )


def load_settings():
    if not os.path.exists(SETTINGS_PATH):
        return {}
    with open(SETTINGS_PATH) as f:
        return json.load(f)


def save_settings(settings):
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    if os.path.exists(SETTINGS_PATH):
        backup_path = SETTINGS_PATH + f".connor-pet-backup.{int(time.time())}"
        shutil.copy2(SETTINGS_PATH, backup_path)
        print(f"backed up existing settings to {backup_path}")
    tmp_path = SETTINGS_PATH + f".tmp.{os.getpid()}"
    with open(tmp_path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, SETTINGS_PATH)


def install():
    settings = load_settings()
    hooks = settings.setdefault("hooks", {})
    added, already_present = [], []

    for event, state in HOOK_EVENTS.items():
        blocks = hooks.setdefault(event, [])

        # Why: never merge into an *existing* block. A block like
        # {"matcher": "Bash", "hooks": [...]} only fires for Bash tool
        # calls — appending our hook there would silently scope it down to
        # just that matcher instead of firing for every event of this type.
        # Always add our own dedicated block instead, so it always fires.
        already_installed = any(
            any(is_connor_pet_entry(h) for h in block.get("hooks", []))
            for block in blocks
        )
        if already_installed:
            already_present.append(event)
            continue

        new_block = {"hooks": [{"type": "command", "command": command_for(state)}]}
        if event in ("PreToolUse", "PostToolUse"):
            new_block["matcher"] = "*"  # explicit "all tools", matching Orca's own convention
        blocks.append(new_block)
        added.append(event)

    save_settings(settings)

    if added:
        print(f"installed hooks for: {', '.join(sorted(set(added)))}")
    if already_present:
        print(f"already installed, left as-is: {', '.join(sorted(set(already_present)))}")
    print(f"wrote {SETTINGS_PATH}")


def uninstall():
    settings = load_settings()
    hooks = settings.get("hooks", {})
    removed = []

    for event in list(hooks.keys()):
        blocks = hooks[event]
        remaining_blocks = []
        for block in blocks:
            block_hooks = block.get("hooks", [])
            kept = [h for h in block_hooks if not is_connor_pet_entry(h)]
            we_modified_this_block = len(kept) != len(block_hooks)
            if we_modified_this_block:
                removed.append(event)
                block["hooks"] = kept
                if not kept:
                    continue  # this was a block we created solely for our hook — drop it entirely
            remaining_blocks.append(block)
        hooks[event] = remaining_blocks
        if not hooks[event]:
            del hooks[event]

    save_settings(settings)
    if removed:
        print(f"removed connor-pet hooks from: {', '.join(sorted(set(removed)))}")
    else:
        print("no connor-pet hooks were installed")


def main():
    if "--uninstall" in sys.argv[1:]:
        uninstall()
    else:
        install()


if __name__ == "__main__":
    main()
