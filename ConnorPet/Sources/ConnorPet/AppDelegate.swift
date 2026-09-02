import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow?
    private var petView: PetView?
    private var statusItem: NSStatusItem?
    private var watcher: AgentStatusWatching?

    // LAN battle: discovers other running copies on the same Wi-Fi and runs the
    // challenge/accept handshake. Peers drive the "대전" submenu; an incoming
    // challenge pops an accept/decline alert; an agreed battle opens a window.
    private var battleService: BattleService?
    private var battlePeers: [BattlePeer] = []
    private var battleWindow: BattleWindow?
    private var pendingChallengeAlert = false

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
        // Test hook: force a specific pet (two instances share one UserDefaults
        // domain, so this lets a headless battle run mismatched characters).
        if let forced = ProcessInfo.processInfo.environment["CONNORPET_PET"],
           petDisplayNames.keys.contains(forced) {
            selectedPetSlug = forced
        }

        guard let sheet = try? Self.loadSpriteSheet(slug: selectedPetSlug) else {
            fatalError("connor-pet: bundled pet '\(selectedPetSlug)' not found")
        }

        let size = petSize
        // Why: NSScreen.main resolves from the key window, which doesn't exist
        // yet during applicationDidFinishLaunching — it can silently return an
        // unexpected screen (observed: a stale/secondary one with a negative
        // origin, placing the window off-screen). screens.first is always the
        // primary display, origin (0,0), independent of window/key state.
        let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = CGPoint(x: screenFrame.maxX - size - 48, y: screenFrame.minY + 48)
        let origin = Self.savedOrigin(fallback: defaultOrigin)
        let contentRect = NSRect(x: origin.x, y: origin.y, width: size, height: size)

        let win = PetWindow(contentRect: contentRect)
        let view = PetView(spriteSheet: sheet)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
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

        startBattleService()
    }

    // MARK: - LAN battle wiring

    private func startBattleService() {
        let service = BattleService(petSlug: selectedPetSlug)
        service.onPeersChanged = { [weak self] peers in
            self?.battlePeers = peers
            self?.rebuildMenu()
            self?.maybeAutoChallenge()
        }
        service.onIncomingChallenge = { [weak self] fromName, respond in
            self?.presentIncomingChallenge(fromName: fromName, respond: respond)
        }
        service.onBattleStart = { [weak self] myRole, outcome, oppName, oppPet in
            self?.presentBattle(myRole: myRole, outcome: outcome, opponentName: oppName, opponentPet: oppPet)
        }
        service.start()
        battleService = service
    }

    // Test hook: when CONNORPET_BATTLE_AUTOCHALLENGE is set, challenge the first
    // discovered peer automatically (drives two real instances without clicks).
    private func maybeAutoChallenge() {
        guard ProcessInfo.processInfo.environment["CONNORPET_BATTLE_AUTOCHALLENGE"] != nil,
              battleWindow == nil, let peer = battlePeers.first, let service = battleService else { return }
        service.challenge(peer) { _ in }
    }

    @objc private func challengePeer(_ sender: NSMenuItem) {
        guard let peerID = sender.representedObject as? String,
              let peer = battlePeers.first(where: { $0.id == peerID }),
              let service = battleService else { return }
        // Avoid stacking battles.
        guard battleWindow == nil else { return }
        service.challenge(peer) { [weak self] result in
            switch result {
            case .accepted:
                break // onBattleStart opens the window
            case .declined:
                self?.showInfo(title: "대전 거절됨", text: "\(peer.name)님이 대전을 거절했어요.")
            case .failed:
                self?.showInfo(title: "대전 실패", text: "\(peer.name)님과 연결하지 못했어요.")
            }
        }
    }

    private func presentIncomingChallenge(fromName: String, respond: @escaping (Bool) -> Void) {
        // Test hook: auto-accept without a modal (used to drive two real
        // instances headlessly — see README dev notes).
        if ProcessInfo.processInfo.environment["CONNORPET_BATTLE_AUTOACCEPT"] != nil {
            respond(battleWindow == nil)
            return
        }
        // If we're already in / setting up a battle, auto-decline.
        guard battleWindow == nil, !pendingChallengeAlert else { respond(false); return }
        pendingChallengeAlert = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "대전 신청"
        alert.informativeText = "\(fromName)님이 대전을 신청했어요. 수락할까요?"
        alert.addButton(withTitle: "수락")
        alert.addButton(withTitle: "거절")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        pendingChallengeAlert = false
        respond(accepted)
    }

    private func presentBattle(myRole: BattleRole, outcome: BattleOutcome, opponentName: String, opponentPet: String) {
        guard battleWindow == nil else { return }
        guard let mySheet = try? Self.loadSpriteSheet(slug: selectedPetSlug) else { return }
        // Fall back to our own sheet if the opponent's pet isn't bundled here.
        let oppSheet = (try? Self.loadSpriteSheet(slug: opponentPet)) ?? mySheet

        let view = BattleView(
            mySheet: mySheet,
            oppSheet: oppSheet,
            myName: "나",
            oppName: opponentName,
            myRole: myRole,
            outcome: outcome
        )
        let win = BattleWindow(view: view) { [weak self] in
            self?.battleWindow = nil
        }
        battleWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        view.start()
    }

    private func showInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        alert.runModal()
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
        menu.addItem(makeBattleMenuItem())

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String, slug != selectedPetSlug else { return }
        guard let sheet = try? Self.loadSpriteSheet(slug: slug) else { return }
        selectedPetSlug = slug
        petView?.setSpriteSheet(sheet)
        Self.savePetSlug(slug)
        battleService?.updatePet(slug) // re-advertise so peers see our new character
        rebuildMenu()
    }

    // MARK: - Menu-bar battle submenu

    /// Builds the "대전" item. Its submenu lists everyone currently discovered on
    /// the same Wi-Fi; picking one sends them a challenge. Shows a disabled
    /// placeholder while nobody's around yet.
    private func makeBattleMenuItem() -> NSMenuItem {
        let battleItem = NSMenuItem(title: "대전", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if battlePeers.isEmpty {
            let empty = NSMenuItem(title: "주변에 상대가 없어요", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for peer in battlePeers {
                let item = NSMenuItem(title: "\(peer.name)에게 신청", action: #selector(challengePeer(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                submenu.addItem(item)
            }
        }
        battleItem.submenu = submenu
        return battleItem
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
            self?.petView?.setBaseAnimation(result.animation)
        }
        newWatcher.start()
        watcher = newWatcher
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
