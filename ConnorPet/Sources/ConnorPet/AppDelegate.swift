import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow?
    private var petView: PetView?
    private var statusItem: NSStatusItem?
    private var watcher: OrcaStatusWatcher?

    // Mirrors Orca's own pet-overlay sizing (`src/shared/pet-types.ts`):
    // PET_SIZE_MIN=60, PET_SIZE_MAX=360, PET_SIZE_DEFAULT=180 — independent of
    // the sprite sheet's native 200x200 frame, which is scaled to fit.
    private let petSize: CGFloat = 180

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar utility, no Dock icon

        guard
            let spritesheetURL = Bundle.module.url(forResource: "spritesheet", withExtension: "png"),
            let manifestURL = Bundle.module.url(forResource: "pet", withExtension: "json")
        else {
            fatalError("connor-pet: bundled spritesheet.png/pet.json not found")
        }

        let sheet: SpriteSheet
        do {
            sheet = try SpriteSheet(manifestURL: manifestURL, spritesheetURL: spritesheetURL)
        } catch {
            fatalError("connor-pet: failed to load sprite bundle: \(error)")
        }

        let size = petSize
        // Why: NSScreen.main resolves from the key window, which doesn't exist
        // yet during applicationDidFinishLaunching — it can silently return an
        // unexpected screen (observed: a stale/secondary one with a negative
        // origin, placing the window off-screen). screens.first is always the
        // primary display, origin (0,0), independent of window/key state.
        let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: screenFrame.maxX - size - 48, y: screenFrame.minY + 48)
        let contentRect = NSRect(x: origin.x, y: origin.y, width: size, height: size)

        let win = PetWindow(contentRect: contentRect)
        let view = PetView(spriteSheet: sheet)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        view.onRequestWindowMove = { [weak win] newOrigin in
            win?.setFrameOrigin(newOrigin)
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)

        window = win
        petView = view

        setUpStatusItem(displayName: sheet.manifest.displayName ?? "connor-pet")

        let w = OrcaStatusWatcher()
        w.onUpdate = { [weak self] result in
            self?.petView?.setBaseAnimation(result.animation)
        }
        w.start()
        watcher = w
    }

    private func setUpStatusItem(displayName: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "🐊"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: displayName, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
