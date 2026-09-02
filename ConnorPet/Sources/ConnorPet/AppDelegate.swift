import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow?
    private var petView: PetView?
    private var statusItem: NSStatusItem?
    private var watcher: AgentStatusWatching?

    // Orca's own default (PET_SIZE_DEFAULT=180) still read as "big" next to the
    // small nav-badge-style pet icon the user is comparing against — sized
    // near Orca's PET_SIZE_MIN=60 floor instead.
    private let petSize: CGFloat = 90

    // Every bundled pet lives at Resources/pets/<slug>/{spritesheet.png,pet.json}
    // (see scripts/build_sheet.py's PETS list, which is the source of truth for
    // this set). Display names shown in the menu come from each pet's own
    // manifest rather than being duplicated here.
    private static let availablePetSlugs = ["totodile", "ditto", "charmander", "squirtle", "geodude", "eevee", "chikorita", "torchic"]
    private var petDisplayNames: [String: String] = [:]
    private var selectedPetSlug = availablePetSlugs[0]

    // Which live status source drives the pet's animation. "claude-code" polls
    // ~/.claude/sessions/*.json every 250ms; "orca" polls Orca's last-status.json
    // every 1s (see ClaudeCodeStatusWatcher/OrcaStatusWatcher).
    private static let availableStatusSources = ["claude-code", "orca"]
    private static let statusSourceDisplayNames = ["claude-code": "Claude Code", "orca": "Orca"]
    private var selectedStatusSource = availableStatusSources[0]

    // Evolution chains keyed by the base pet the user picks: stage 1 → first
    // evolution, stage 2 → second (see XPModel.stage). The evolved forms are
    // bundled just like the base pets (scripts/build_sheet.py builds them from
    // each next PokéDex form) but aren't offered in the picker — evolution is
    // automatic, driven by token-usage XP. Ditto has no evolution.
    private static let evolutionChains: [String: [String]] = [
        "totodile": ["croconaw", "feraligatr"],
        "charmander": ["charmeleon", "charizard"],
        "squirtle": ["wartortle", "blastoise"],
        "geodude": ["graveler", "golem"],
        "chikorita": ["bayleef", "meganium"],
        "torchic": ["combusken", "blaziken"],
        "eevee": ["vaporeon"],
        "ditto": [],
    ]

    // Evolution % thresholds [stage1, stage2], configurable from the menu bar.
    // Kept strictly increasing (stage1 < stage2). Defaults match XPModel's PoC
    // values (10% / 30%).
    private var evolutionThresholds: [Double] = XPModel.stageThresholds
    // Preset percentages offered in the menu for each stage.
    private static let thresholdPresets: [Double] = [0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.70]
    // Whether the pet evolves at all (menu toggle). When off it stays the base
    // form regardless of XP. Default on.
    private var evolutionEnabled = true

    // Whether the XP bar is always shown vs. only on hover (menu toggle).
    private var barAlwaysVisible = true
    // Live XP state, so re-selecting a pet re-derives the right evolved form.
    private var currentStage = 0
    private var currentPercent: Double = 0
    private var currentDisplaySlug = ""
    private var sheetCache: [String: SpriteSheet] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar utility, no Dock icon

        for slug in Self.availablePetSlugs {
            if let sheet = try? Self.loadSpriteSheet(slug: slug) {
                petDisplayNames[slug] = sheet.manifest.displayName ?? slug
            }
        }

        selectedPetSlug = Self.savedPetSlug(
            fallback: Self.availablePetSlugs.first ?? "totodile",
            validSlugs: Set(petDisplayNames.keys)
        )

        guard let sheet = try? Self.loadSpriteSheet(slug: selectedPetSlug) else {
            fatalError("connor-pet: bundled pet '\(selectedPetSlug)' not found")
        }

        let size = petSize
        // The window is one square (the sprite) plus a short strip beneath it
        // for the XP bar, so the pet still renders at `size` while the bar sits
        // below it (see PetView.barAreaHeight).
        let viewHeight = size + PetView.barAreaHeight
        // Why: NSScreen.main resolves from the key window, which doesn't exist
        // yet during applicationDidFinishLaunching — it can silently return an
        // unexpected screen (observed: a stale/secondary one with a negative
        // origin, placing the window off-screen). screens.first is always the
        // primary display, origin (0,0), independent of window/key state.
        let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = CGPoint(x: screenFrame.maxX - size - 48, y: screenFrame.minY + 48)
        let origin = Self.savedOrigin(fallback: defaultOrigin)
        let contentRect = NSRect(x: origin.x, y: origin.y, width: size, height: viewHeight)

        currentDisplaySlug = selectedPetSlug
        sheetCache[selectedPetSlug] = sheet

        let win = PetWindow(contentRect: contentRect)
        let view = PetView(spriteSheet: sheet)
        view.frame = NSRect(x: 0, y: 0, width: size, height: viewHeight)
        barAlwaysVisible = Self.savedBarAlwaysVisible(fallback: false)
        view.setBarAlwaysVisible(barAlwaysVisible)
        evolutionThresholds = Self.savedEvolutionThresholds(fallback: XPModel.stageThresholds)
        evolutionEnabled = Self.savedEvolutionEnabled(fallback: true)
        view.setBarEnabled(evolutionEnabled) // evolution off → no bar at all
        view.onRequestWindowMove = { [weak win] newOrigin in
            win?.setFrameOrigin(newOrigin)
            Self.saveOrigin(newOrigin)
        }
        view.onHoverEnter = { [weak self] in
            self?.watcher?.acknowledgeDone()
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)

        window = win
        petView = view

        setUpStatusItem()

        selectedStatusSource = Self.savedStatusSource(fallback: Self.availableStatusSources[0])
        startWatcher(for: selectedStatusSource)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeStatusIcon()
        statusItem = item
        rebuildMenu()
    }

    // MARK: - Menu-bar pet picker

    private func rebuildMenu() {
        let menu = NSMenu()
        // We manage enablement ourselves (to gray out the threshold submenu when
        // evolution is off); every other item defaults to enabled.
        menu.autoenablesItems = false
        for slug in Self.availablePetSlugs {
            guard let title = petDisplayNames[slug] else { continue } // resources missing for this slug — skip it
            let menuItem = NSMenuItem(title: title, action: #selector(selectPet(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = slug
            menuItem.state = (slug == selectedPetSlug) ? .on : .off
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        for source in Self.availableStatusSources {
            let title = Self.statusSourceDisplayNames[source] ?? source
            let menuItem = NSMenuItem(title: title, action: #selector(selectStatusSource(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = source
            menuItem.state = (source == selectedStatusSource) ? .on : .off
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        // When on, the XP bar is always visible; when off, it only appears while
        // hovering the pet. Default on (see savedBarAlwaysVisible).
        let barToggle = NSMenuItem(title: "경험치 바 항상 표시", action: #selector(toggleBarAlwaysVisible), keyEquivalent: "")
        barToggle.target = self
        barToggle.state = barAlwaysVisible ? .on : .off
        menu.addItem(barToggle)

        // Master on/off for evolution. When off the pet stays its base form.
        let evoToggle = NSMenuItem(title: "진화 사용", action: #selector(toggleEvolutionEnabled), keyEquivalent: "")
        evoToggle.target = self
        evoToggle.state = evolutionEnabled ? .on : .off
        menu.addItem(evoToggle)

        // Evolution thresholds: a submenu with one sub-submenu per stage, each
        // listing preset percentages (checkmark on the current choice). Grayed
        // out while evolution is disabled (the values still persist).
        let evoTitle = "진화 % 설정 (\(Self.pct(evolutionThresholds[0])) / \(Self.pct(evolutionThresholds[1])))"
        let evoItem = NSMenuItem(title: evoTitle, action: nil, keyEquivalent: "")
        evoItem.isEnabled = evolutionEnabled
        let evoMenu = NSMenu()
        evoMenu.addItem(makeThresholdSubmenu(title: "1단계 진화", stageIndex: 0))
        evoMenu.addItem(makeThresholdSubmenu(title: "2단계 진화", stageIndex: 1))
        evoItem.submenu = evoMenu
        menu.addItem(evoItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func toggleBarAlwaysVisible() {
        barAlwaysVisible.toggle()
        petView?.setBarAlwaysVisible(barAlwaysVisible)
        Self.saveBarAlwaysVisible(barAlwaysVisible)
        rebuildMenu()
    }

    // MARK: - Menu-bar evolution controls

    @objc private func toggleEvolutionEnabled() {
        evolutionEnabled.toggle()
        Self.saveEvolutionEnabled(evolutionEnabled)
        petView?.setBarEnabled(evolutionEnabled) // hide/show the bar entirely
        applyStage() // evolve to the earned stage, or revert to base, immediately
        rebuildMenu()
    }

    /// Builds the per-stage sub-submenu of preset percentages. `tag` carries the
    /// stage index and `representedObject` the chosen fraction.
    private func makeThresholdSubmenu(title: String, stageIndex: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = evolutionThresholds[stageIndex]
        for preset in Self.thresholdPresets {
            let sub = NSMenuItem(title: Self.pct(preset), action: #selector(selectThreshold(_:)), keyEquivalent: "")
            sub.target = self
            sub.tag = stageIndex
            sub.representedObject = NSNumber(value: preset)
            sub.state = (abs(preset - current) < 0.0001) ? .on : .off
            submenu.addItem(sub)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        setThreshold(stageIndex: sender.tag, value: value)
    }

    /// Sets one stage's threshold, keeping the pair strictly increasing
    /// (stage 1 < stage 2) by nudging the other stage when they'd cross.
    private func setThreshold(stageIndex: Int, value: Double) {
        var t = evolutionThresholds
        t[stageIndex] = value
        if stageIndex == 0, t[0] >= t[1] {
            t[1] = Self.thresholdPresets.first(where: { $0 > t[0] }) ?? t[0]
        } else if stageIndex == 1, t[1] <= t[0] {
            t[0] = Self.thresholdPresets.last(where: { $0 < t[1] }) ?? t[1]
        }
        evolutionThresholds = t
        Self.saveEvolutionThresholds(t)
        applyStage() // re-evaluate against the new thresholds right away
        rebuildMenu()
    }

    private static func pct(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String, slug != selectedPetSlug else { return }
        selectedPetSlug = slug
        Self.savePetSlug(slug)
        // Re-derive the shown form from the new base + current XP stage (so
        // picking a pet while already "leveled up" shows its evolved form).
        refreshDisplayedPet()
        rebuildMenu()
    }

    // MARK: - Menu-bar status-source picker

    @objc private func selectStatusSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String, source != selectedStatusSource else { return }
        selectedStatusSource = source
        Self.saveStatusSource(source)
        startWatcher(for: source)
        rebuildMenu()
    }

    private func startWatcher(for source: String) {
        watcher?.stop()
        let newWatcher: AgentStatusWatching = (source == "orca") ? OrcaStatusWatcher() : ClaudeCodeStatusWatcher()
        newWatcher.onUpdate = { [weak self] result in
            self?.applyUpdate(result)
        }
        newWatcher.start()
        watcher = newWatcher
    }

    // MARK: - Live update: animation + XP bar + evolution

    private func applyUpdate(_ result: AgentStateAnimationResult) {
        petView?.setBaseAnimation(result.animation)
        currentPercent = XPModel.percent(contextTokens: result.contextTokens)
        applyStage()
    }

    /// Applies the current XP to the bar and evolution. When evolution is
    /// disabled the pet is pinned to its base form (stage 0) and the bar is
    /// hidden entirely. The bar fill is progress toward the *next* threshold
    /// (see XPModel.barFill), not absolute percent. Called both on each poll and
    /// immediately after a menu change (thresholds / enable toggle).
    private func applyStage() {
        let stage = evolutionEnabled ? XPModel.stage(percent: currentPercent, thresholds: evolutionThresholds) : 0
        let fill = evolutionEnabled ? XPModel.barFill(percent: currentPercent, thresholds: evolutionThresholds) : 0
        petView?.setProgress(percent: fill, stage: stage)
        if stage != currentStage {
            currentStage = stage
            refreshDisplayedPet()
        }
    }

    /// Picks the sprite to show from the user's base pet + current evolution
    /// stage, swapping it in only when it actually changes (so the animation
    /// isn't restarted every poll).
    private func refreshDisplayedPet() {
        let slug = displaySlug(base: selectedPetSlug, stage: currentStage)
        guard slug != currentDisplaySlug, let sheet = cachedSheet(slug: slug) else { return }
        currentDisplaySlug = slug
        petView?.setSpriteSheet(sheet)
    }

    private func displaySlug(base: String, stage: Int) -> String {
        guard stage > 0, let chain = Self.evolutionChains[base], !chain.isEmpty else { return base }
        let index = min(stage, chain.count) - 1
        return chain[index]
    }

    private func cachedSheet(slug: String) -> SpriteSheet? {
        if let cached = sheetCache[slug] { return cached }
        guard let sheet = try? Self.loadSpriteSheet(slug: slug) else { return nil }
        sheetCache[slug] = sheet
        return sheet
    }

    private static func loadSpriteSheet(slug: String) throws -> SpriteSheet {
        guard
            let spritesheetURL = Bundle.module.url(forResource: "spritesheet", withExtension: "png", subdirectory: "pets/\(slug)"),
            let manifestURL = Bundle.module.url(forResource: "pet", withExtension: "json", subdirectory: "pets/\(slug)")
        else {
            throw NSError(domain: "ConnorPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing bundled resources for pet '\(slug)'"])
        }
        return try SpriteSheet(manifestURL: manifestURL, spritesheetURL: spritesheetURL)
    }

    // Menu-bar glyph for the Totodile pet: a Poké Ball outline, drawn to match
    // the monochrome/template style of the other system status-bar icons
    // (color is ignored for template images — only the alpha shape matters).
    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 1.4
            let ballRect = rect.insetBy(dx: 2, dy: 2)

            let outline = NSBezierPath(ovalIn: ballRect)
            outline.lineWidth = lineWidth
            NSColor.black.setStroke()
            outline.stroke()

            let midY = rect.midY
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: ballRect.minX, y: midY))
            divider.line(to: NSPoint(x: ballRect.maxX, y: midY))
            divider.lineWidth = lineWidth
            divider.stroke()

            let hubRadius: CGFloat = 2.6
            let hubRect = NSRect(
                x: rect.midX - hubRadius, y: midY - hubRadius,
                width: hubRadius * 2, height: hubRadius * 2
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: hubRect).fill()

            let holeRadius: CGFloat = 1.1
            let holeRect = NSRect(
                x: rect.midX - holeRadius, y: midY - holeRadius,
                width: holeRadius * 2, height: holeRadius * 2
            )
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: holeRect).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Selected pet persistence

    private static let selectedPetDefaultsKey = "selectedPetSlug"

    private static func savePetSlug(_ slug: String) {
        UserDefaults.standard.set(slug, forKey: selectedPetDefaultsKey)
    }

    // Falls back to `fallback` if nothing was saved yet, or if the saved slug
    // no longer has bundled resources (e.g. removed from a future build).
    private static func savedPetSlug(fallback: String, validSlugs: Set<String>) -> String {
        guard let saved = UserDefaults.standard.string(forKey: selectedPetDefaultsKey), validSlugs.contains(saved) else {
            return fallback
        }
        return saved
    }

    // MARK: - Selected status-source persistence

    private static let selectedStatusSourceDefaultsKey = "selectedStatusSource"

    private static func saveStatusSource(_ source: String) {
        UserDefaults.standard.set(source, forKey: selectedStatusSourceDefaultsKey)
    }

    // Falls back to `fallback` ("claude-code") if nothing was saved yet, or if
    // the saved value isn't one of the sources this build knows about.
    private static func savedStatusSource(fallback: String) -> String {
        guard let saved = UserDefaults.standard.string(forKey: selectedStatusSourceDefaultsKey),
              availableStatusSources.contains(saved) else {
            return fallback
        }
        return saved
    }

    // MARK: - XP bar visibility persistence

    private static let barAlwaysVisibleDefaultsKey = "xpBarAlwaysVisible"

    private static func saveBarAlwaysVisible(_ always: Bool) {
        UserDefaults.standard.set(always, forKey: barAlwaysVisibleDefaultsKey)
    }

    // Defaults to `fallback` (false — bar only on hover) when nothing saved yet.
    private static func savedBarAlwaysVisible(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: barAlwaysVisibleDefaultsKey) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: barAlwaysVisibleDefaultsKey)
    }

    // MARK: - Evolution settings persistence

    private static let evolutionThresholdsDefaultsKey = "evolutionThresholds"
    private static let evolutionEnabledDefaultsKey = "evolutionEnabled"

    private static func saveEvolutionThresholds(_ thresholds: [Double]) {
        UserDefaults.standard.set(thresholds, forKey: evolutionThresholdsDefaultsKey)
    }

    // Falls back to `fallback` unless a valid [stage1, stage2] pair was saved
    // (two fractions in 0...1, strictly increasing).
    private static func savedEvolutionThresholds(fallback: [Double]) -> [Double] {
        guard let saved = UserDefaults.standard.array(forKey: evolutionThresholdsDefaultsKey) as? [Double],
              saved.count == 2,
              saved.allSatisfy({ $0 >= 0 && $0 <= 1 }),
              saved[0] <= saved[1] else {
            return fallback
        }
        return saved
    }

    private static func saveEvolutionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: evolutionEnabledDefaultsKey)
    }

    // Defaults to `fallback` (true — evolution on) when nothing saved yet.
    private static func savedEvolutionEnabled(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: evolutionEnabledDefaultsKey) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: evolutionEnabledDefaultsKey)
    }

    // MARK: - Window position persistence

    private static let originDefaultsKey = "petWindowOrigin"

    private static func saveOrigin(_ origin: CGPoint) {
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: originDefaultsKey)
    }

    // Falls back to `fallback` if nothing was saved yet, or if the saved spot
    // no longer lands on any connected screen (e.g. monitor unplugged since).
    private static func savedOrigin(fallback: CGPoint) -> CGPoint {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: originDefaultsKey),
            let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat
        else { return fallback }

        let saved = CGPoint(x: x, y: y)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(saved) }
        return onScreen ? saved : fallback
    }
}
