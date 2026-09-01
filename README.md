# connor-pet

[한국어](README.ko.md)

A desktop pet — 리아코 (Totodile, #158) — that reacts to your real
[Orca](https://github.com/stablyai/orca) agent/project status. Built as a
standalone macOS app, **not** as an Orca-imported `.codex-pet` bundle: this
runs as its own process and reads Orca's state from outside.

## Why this is possible

Orca's hook server persists every agent pane's live status to disk
(`src/main/agent-hooks/server/server-persistence.ts`), debounced at 250ms:

```
~/Library/Application Support/Orca/agent-hooks/last-status.json
```

This is the same file Orca itself reads to restore state across restarts, so
it's a stable, intentional read surface — not a hack. Shape:

```json
{
  "version": 2,
  "entries": {
    "<paneKey>": {
      "state": "working" | "blocked" | "waiting" | "done",
      "workingMode": "monitoring",
      "worktreeId": "...",
      "receivedAt": 1735000000000
    }
  }
}
```

`ConnorPet` polls this file once a second (well within Orca's own write
cadence) and runs the same precedence rule Orca's own pet uses
(`pet-agent-state.ts`'s `agentStateAnimation`) over every entry, across every
project/worktree you have open in Orca:

1. any pane `blocked`/`waiting` → **waiting** (highest priority, short-circuits)
2. else any pane `working` → **running**
3. else any pane `done` → **review**
4. else → **idle**

Hover the pet → **jumping**. Drag it → **running-left**/**running-right**,
following the pointer.

### What each state actually looks like

![idle / running / waiting / review](docs/pet-states.png)

`idle` and `running` are mostly distinguished by motion (a slow ambient bob
vs. a fast bounce) rather than color, so they read closer together as static
frames than they do live. `waiting` is desaturated, `review` gets a warm
golden tint — both ported directly from `codex-pet-sprite-defaults.ts`'s
per-row treatment.

## Layout

```
totodile.codex-pet/     Real Orca-importable bundle (Settings → Experimental → Pet → Import)
  pet.json                Manifest: 9-row sprite layout, per-frame timing
  spritesheet.png          800x1800, 4 cols x 9 rows, 200x200 frames

scripts/build_sheet.py  Reproducible generator — re-downloads PokeAPI's gen5
                         battle sprites for Totodile (#158) and rebuilds the
                         sheet from scratch (`python3 scripts/build_sheet.py`)

preview/index.html       Browser-only preview: loads the real spritesheet.png +
                          pet.json and steps frames with Orca's actual CSS
                          algorithm (buildSpriteAnimationCss), with a simulated
                          multi-project/multi-agent control panel. No Orca
                          install required.

ConnorPet/                The real deliverable: a standalone macOS app
  Package.swift             (Swift Package, `swift run` — no Xcode needed)
  Sources/ConnorPet/
    OrcaStatusWatcher.swift   Polls last-status.json, computes the aggregate state
    PetAnimationState.swift   Ported precedence logic + drag-direction hysteresis
    SpriteSheet.swift         Slices spritesheet.png into per-animation frame arrays
    PetView.swift              Draws frames, handles hover/drag
    PetWindow.swift             Borderless, transparent, always-on-top NSWindow
    AppDelegate.swift            Wires it all together, adds a menu-bar Quit item
    Resources/                   Bundled copies of spritesheet.png + pet.json
```

## Running the Swift app

```sh
cd ConnorPet
swift run
```

A small 🐊 menu-bar item appears (right-click → Quit to stop it). The pet
itself floats near the bottom-right of your main display, above other
windows, on every Space. If Orca isn't installed or has no active agent
panes, it just idles.

## Using the bundle inside Orca instead

If you'd rather have Orca render 리아코 itself (Settings → Experimental →
Pet → Import a `.codex-pet` bundle), point the importer at the
`totodile.codex-pet/` folder directly.

## Regenerating the sprite sheet

```sh
pip install pillow
python3 scripts/build_sheet.py
```

Re-downloads Totodile's animated gen5 battle sprites from PokeAPI's sprite
mirror and rebuilds `totodile.codex-pet/{spritesheet.png,pet.json}` from
scratch — fully reproducible, no binary source assets committed.

## Credits / license

Character sprites are derived from Nintendo/Game Freak/Creatures Inc.'s
Pokémon assets via [PokeAPI](https://pokeapi.co/); personal/demo use only,
not for redistribution as a standalone asset. All original code in this repo
(build script, Swift app, preview page) is otherwise free to reuse.
