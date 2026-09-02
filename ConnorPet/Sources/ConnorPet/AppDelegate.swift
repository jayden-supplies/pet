import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow?
    private var petView: PetView?
    private var statusItem: NSStatusItem?
    private var bubble: SpeechBubbleWindow?

    // 브리핑 범위는 2단이다.
    //   1순위 — 최근 3시간 안에 쓴 세션. "지금 하던 일"이 이 안에 있다.
    //   2순위 — 1순위가 하나도 없을 때만, 48시간까지 넓혀서 3개.
    // 1순위에 상한 5를 둔 건 말풍선 글자 예산(세션당 100자 / 합계 500자)이
    // 어차피 다섯 줄에서 끊기기 때문이다. 더 뽑아 봐야 버려진다.
    private let briefPrimaryHours: Double = 3
    private let briefPrimaryLimit = 5
    private let briefFallbackHours: Double = 48
    private let briefFallbackLimit = 3
    private let briefCharsPerSession = 100
    private let briefCharBudget = 500
    private var watcher: AgentStatusWatching?

    // Orca's own default (PET_SIZE_DEFAULT=180) still read as "big" next to the
    // small nav-badge-style pet icon the user is comparing against — sized
    // near Orca's PET_SIZE_MIN=60 floor instead.
    private let petSize: CGFloat = 90

    // Every bundled pet lives at Resources/pets/<slug>/{spritesheet.png,pet.json}
    // (see scripts/build_sheet.py's PETS list, which is the source of truth for
    // this set). Display names shown in the menu come from each pet's own
    // manifest rather than being duplicated here.
    private static let availablePetSlugs = ["totodile", "ditto", "charmander", "squirtle", "geodude", "eevee", "chikorita", "torchic", "tepig"]
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
        view.onRequestWindowMove = { [weak win, weak self] newOrigin in
            win?.setFrameOrigin(newOrigin)
            Self.saveOrigin(newOrigin)
            self?.bubble?.hide() // the bubble does not follow a drag; drop it
        }
        view.onClick = { [weak self] in self?.briefingText() }
        view.onSpeak = { [weak self] text, duration in
            guard let self, let petFrame = self.window?.frame else { return }
            self.bubble?.show(text: text, above: petFrame, duration: duration)
        }
        view.onSilence = { [weak self] in self?.bubble?.hide() }
        view.onHoverEnter = { [weak self] in
            self?.watcher?.acknowledgeDone()
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)

        window = win
        petView = view
        bubble = SpeechBubbleWindow()

        setUpStatusItem()

        selectedStatusSource = Self.savedStatusSource(fallback: Self.availableStatusSources[0])
        startWatcher(for: selectedStatusSource)

        if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
            let text = briefingText() ?? "(브리핑 없음)"
            FileHandle.standardError.write("[connor-pet] 클릭 브리핑 미리보기 (\(text.count)자):\n\(text)\n".data(using: .utf8)!)
            // 클릭 없이도 말풍선 레이아웃을 눈으로 확인할 수 있게 바로 한 번 띄운다.
            if let petFrame = window?.frame {
                bubble?.show(text: text, above: petFrame, duration: 60)
                // 화면 캡처 권한 없이도 말풍선 레이아웃을 확인할 수 있게, 뷰를 그대로
                // PNG 로 떠서 남긴다. CONNORPET_DEBUG_SHOT 에 경로를 주면 저장된다.
                if let path = ProcessInfo.processInfo.environment["CONNORPET_DEBUG_SHOT"],
                   let view = bubble?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                        FileHandle.standardError.write("[connor-pet] 말풍선 렌더 저장: \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))\n".data(using: .utf8)!)
                    }
                }
            }
        }
    }

    // MARK: - Briefing

    /// What the pet says when clicked: the most recent sessions and what each
    /// one was started to do. Reads Claude Code's own transcripts, so it covers
    /// both the CLI and the desktop app without either being running.
    private func briefingText() -> String? {
        var briefs = SessionBriefReader.recent(
            withinHours: briefPrimaryHours,
            limit: briefPrimaryLimit,
            perBriefChars: briefCharsPerSession
        )
        var isFallback = false
        if briefs.isEmpty {
            briefs = SessionBriefReader.recent(
                withinHours: briefFallbackHours,
                limit: briefFallbackLimit,
                perBriefChars: briefCharsPerSession
            )
            isFallback = true
        }
        guard !briefs.isEmpty else {
            return "최근 \(Int(briefFallbackHours))시간 안에 작업한 게 없어. 푹 쉬었구나?"
        }

        var lines: [String] = []
        // 2순위로 내려왔다는 건 방금까지 한 일이 아니라는 뜻이라, 그렇다고 말해 준다.
        // 안 그러면 이틀 전 작업을 지금 하던 일로 읽는다.
        if isFallback {
            lines.append("최근 \(Int(briefPrimaryHours))시간은 조용했어. 그 전엔 이런 걸 했어.")
        }
        // 접두 문장도 말풍선에 들어가므로 예산에 포함해서 센다.
        var used = lines.reduce(0) { $0 + $1.count }
        for brief in briefs {
            let line = "· [\(brief.project)] \(brief.text)"
            // Budget is on the spoken text as a whole, so a long early brief
            // costs later ones their slot rather than overflowing the bubble.
            if used + line.count > briefCharBudget { break }
            used += line.count
            lines.append(line)
        }
        return lines.joined(separator: "\n")
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
