import AppKit

/// `CONNORPET_SELFTEST=paste swift run`. 설정 창의 API 키 입력란에 **붙여넣기가 되는지**
/// 확인한다.
///
/// 이 앱은 `.accessory` 라 메뉴 막대를 그리지 않는데, ⌘V 는 `NSApp.mainMenu` 를 뒤져서
/// 처리된다. 메뉴가 없으면 갈 곳이 없어 아무 일도 일어나지 않았다 — 그래서 키를 복사해
/// 와도 붙일 수가 없었다.
///
/// 메뉴 항목이 있는지만 보지 않고 **실제로 붙여 본다**. 항목이 있어도 셀렉터나 응답자
/// 사슬이 어긋나면 여전히 안 붙기 때문이다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runPasteSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    // 자체검증은 앱 설정보다 먼저 도므로 NSApplication 을 여기서 만든다.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    EditMenu.install()

    guard let main = NSApp.mainMenu else { fail("메인 메뉴가 없다") }
    let items = main.items.compactMap(\.submenu).flatMap(\.items)
    guard let paste = items.first(where: { $0.action == #selector(NSText.paste(_:)) }) else {
        fail("붙여넣기 항목이 없다")
    }
    guard paste.keyEquivalent == "v", paste.keyEquivalentModifierMask.contains(.command) else {
        fail("붙여넣기 단축키가 ⌘V 가 아니다: \(paste.keyEquivalentModifierMask)/\(paste.keyEquivalent)")
    }
    // 첫 항목(앱 메뉴 자리)을 비워 두지 않으면 편집 메뉴가 그 자리로 밀려 단축키를 놓친다.
    guard main.items.count >= 2, main.items[0].submenu == nil else {
        fail("앱 메뉴 자리가 비어 있지 않다 — 편집 메뉴가 앱 메뉴로 잡힌다")
    }
    print("[selftest] 편집 메뉴: 붙여넣기 ⌘V 등록됨")

    // 실제로 붙여 본다. 키를 그대로 흉내 낸 값이지만 진짜 키가 아니다.
    //
    // NSApp.sendAction(to: nil) 은 앱 이벤트 루프가 돌아야 응답자를 찾는다.
    // RunLoop 만 돌려서는 key 창이 서지 않으므로 app.run() 안에서 시험한다.
    let runner = PasteTestRunner(fail: fail)
    app.delegate = runner
    app.run()
    fatalError("앱이 끝났다")
}

/// 붙여넣기 시험을 앱이 뜬 뒤에 돌린다. `applicationDidFinishLaunching` 시점이면
/// 응답자 사슬과 key 창이 실제 사용 때와 같다.
private final class PasteTestRunner: NSObject, NSApplicationDelegate {
    private let fail: (String) -> Never
    private var window: NSWindow?

    init(fail: @escaping (String) -> Never) {
        self.fail = fail
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let pasted = "lin_api_pastecheck_0000"
        let board = NSPasteboard.general
        // 사용자의 클립보드를 빌려 쓰므로 반드시 되돌려 놓는다.
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(pasted, forType: .string)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
        window.contentView?.addSubview(field)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let restore = {
                board.clearContents()
                if let saved { board.setString(saved, forType: .string) }
            }
            guard window.makeFirstResponder(field) else {
                restore(); self.fail("입력란이 포커스를 못 받았다")
            }
            // ⌘V 가 실제로 하는 일 — 메뉴의 동작을 응답자 사슬로 보낸다. 받는 것은
            // 입력란이 아니라 창의 필드 에디터(NSTextView)다.
            guard NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) else {
                restore(); self.fail("붙여넣기 동작을 받아 줄 응답자가 없다")
            }
            let got = field.stringValue
            restore()

            guard got == pasted else { restore(); self.fail("붙여넣기가 안 됐다: \"\(got)\"") }
            print("[selftest] 입력란에 실제로 붙여넣어졌다 (\(got.count)자)")
            print("[selftest] 사용자 클립보드는 원래대로 되돌렸다")
            print("SELFTEST PASS")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.fail("시간 초과") }
    }
}
