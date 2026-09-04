import Foundation
import Network

/// A peer discovered on the local network — another running copy of this app,
/// advertising itself via Bonjour. `id` is that instance's process-unique UUID
/// (so we can filter ourselves out and de-dupe), `name`/`pet` come from its TXT
/// record for display, and `endpoint` is what we dial to challenge it.
struct BattlePeer: Equatable {
    let id: String
    let name: String
    let pet: String
    let endpoint: NWEndpoint

    static func == (lhs: BattlePeer, rhs: BattlePeer) -> Bool { lhs.id == rhs.id }
}

/// Wire protocol between two apps. One flat Codable envelope keeps framing
/// trivial; unused fields stay nil per message kind.
///
///   challenger →  challenge {version, fromID, fromName, fromPet, power}
///   accepter   →  accept {version, fromID, fromName, fromPet, seed, outcome}
///                 or decline {}
///   누구든    →  stare {fromID, fromName, fromPet}   (노려보기 — 응답 없음)
///
/// **결과는 받는 쪽(accepter)이 계산해서 통째로 보낸다.** 예전에는 시드만 주고받고
/// 양쪽이 각자 simulateBattle 을 돌렸는데, 그 방식은 두 앱의 전투 규칙이 완전히
/// 같을 때만 성립한다. 한쪽만 업데이트해 회피율이 25%→10% 로 바뀌자 같은 시드에서
/// 서로 다른 승자가 나왔고, 두 화면에 동시에 "WIN" 이 뜨거나 동시에 "LOSE" 가 떴다.
/// 계산 주체를 한쪽으로 몰면 규칙이 앞으로 또 바뀌어도 이 문제가 재발하지 않는다.
///
/// `version` 은 그래도 남겨 둔다 — 결과를 보낼 줄 모르는 구버전과 만나면 대전을
/// 시작하지 않고 "버전이 다르다"고 알려 준다. 틀린 승패를 보여 주는 것보다 낫다.
struct BattleMessage: Codable {
    enum Kind: String, Codable {
        case challenge
        case accept
        case decline
        case stare
    }
    let type: Kind
    /// 전투 규칙·프로토콜 세대. 구버전은 이 필드를 보내지 않아 nil 로 들어온다.
    var version: Int?
    var fromID: String?
    var fromName: String?
    var fromPet: String?
    var seed: UInt64?
    /// 도전하는 쪽 펫의 성장 파워(0...1). 받는 쪽이 전투를 계산할 때 쓴다.
    var power: Double?
    /// 받는 쪽이 계산한 전투 결과. accept 에만 담긴다.
    var outcome: BattleOutcome?
}

/// 전투 규칙과 메시지 형식의 세대. 규칙을 바꿀 때마다 올린다 — 다른 세대끼리는
/// 대전을 시작하지 않는다.
let battleProtocolVersion = 2

/// The Bonjour service type every copy of this app advertises and browses for.
/// (Must be ≤15 chars, letters/digits/hyphen — "connorpet" fits.)
let battleServiceType = "_connorpet._tcp"

/// Discovers other running apps on the same Wi-Fi and runs the challenge/accept
/// handshake that leads into a battle. Pure networking + protocol; it knows
/// nothing about windows or sprites — callers wire the callbacks to UI.
///
/// Lifecycle: `start()` brings up an `NWListener` (advertising us + accepting
/// inbound challenges) and an `NWBrowser` (finding peers). Everything runs on a
/// private serial queue; all callbacks are hopped to the main queue so the UI
/// layer never has to think about threading.
final class BattleService {
    /// This process's unique id — advertised in our TXT record, used by peers
    /// (and us) to recognize and filter self.
    let instanceID = UUID().uuidString
    /// Human label shown in others' peer lists (defaults to the computer name).
    let displayName: String
    /// Currently-selected pet slug; advertised so the opponent can render our
    /// actual character. Updated live via `updatePet(_:)`.
    private(set) var petSlug: String

    /// Fires (on main) whenever the discovered-peer set changes.
    var onPeersChanged: (([BattlePeer]) -> Void)?
    /// Fires (on main) when someone challenges us. Call `respond(true)` to accept
    /// (starts the battle) or `respond(false)` to decline.
    var onIncomingChallenge: ((_ fromName: String, _ respond: @escaping (Bool) -> Void) -> Void)?
    /// Fires (on main) when a battle is agreed (either we accepted an incoming
    /// challenge, or a peer accepted ours). Carries everything the UI needs to
    /// animate: our fixed role, the shared outcome, and the opponent's pet slug.
    var onBattleStart: ((_ myRole: BattleRole, _ outcome: BattleOutcome, _ opponentName: String, _ opponentPet: String) -> Void)?
    /// 누가 노려봤을 때. (보낸 사람 이름, 그쪽 펫 slug)
    var onStare: ((_ fromName: String, _ fromPet: String) -> Void)?
    /// 세대가 다른 상대가 우리에게 대전을 걸어왔을 때. 받는 쪽 사용자에게도 이유를 알린다.
    var onIncompatiblePeer: ((_ fromName: String) -> Void)?

    /// 이 인스턴스가 쓰는 세대. 평소에는 손대지 않는다 — 자체검증이 구버전 상대를
    /// 흉내 내려고 낮춰 잡을 때만 바꾼다.
    var protocolVersion: Int = battleProtocolVersion
    /// 내 펫의 현재 파워(0...1)를 묻는다. 전투 계산에 실어 보낸다.
    var localPower: (() -> Double)?

    private let queue = DispatchQueue(label: "connorpet.battle")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: BattlePeer] = [:]

    /// Connections we've dialed out on, keyed by the peer id we challenged, held
    /// so ARC doesn't tear them down mid-handshake.
    private var outgoing: [String: BattleConnection] = [:]
    /// Inbound connections we've accepted, held until their handshake resolves.
    private var incoming: Set<BattleConnection> = []

    init(displayName: String? = nil, petSlug: String) {
        self.displayName = displayName ?? (Host.current().localizedName ?? "someone")
        self.petSlug = petSlug
    }

    /// Update the advertised pet after the user switches characters in the menu.
    /// Re-publishes the TXT record so peers see the new slug.
    func updatePet(_ slug: String) {
        queue.async {
            guard slug != self.petSlug else { return }
            self.petSlug = slug
            self.listener?.service = self.makeService()
        }
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.startListener()
            self.startBrowser()
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            self.outgoing.values.forEach { $0.cancel() }
            self.incoming.forEach { $0.cancel() }
            self.outgoing.removeAll()
            self.incoming.removeAll()
        }
    }

    private func makeService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = instanceID
        txt["name"] = displayName
        txt["pet"] = petSlug
        // Use the instance UUID as the Bonjour instance name so two copies on
        // the same Mac never collide / get auto-renamed.
        return NWListener.Service(name: instanceID, type: battleServiceType, txtRecord: txt)
    }

    // MARK: - Listener (advertise + accept inbound challenges)

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = makeService()
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleInbound(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    battleLog("listener failed: \(err)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            battleLog("listener setup failed: \(error)")
        }
    }

    private func handleInbound(_ nwConn: NWConnection) {
        let conn = BattleConnection(connection: nwConn, queue: queue)
        incoming.insert(conn)
        conn.onMessage = { [weak self, weak conn] msg in
            guard let self, let conn else { return }
            self.handleInboundMessage(msg, on: conn)
        }
        conn.onClose = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.queue.async { self.incoming.remove(conn) }
        }
        conn.start()
    }

    private func handleInboundMessage(_ msg: BattleMessage, on conn: BattleConnection) {
        // 노려보기는 응답이 없다. 알림만 띄우고 연결을 닫는다.
        if msg.type == .stare {
            let name = msg.fromName ?? "누군가"
            let pet = msg.fromPet ?? ""
            DispatchQueue.main.async { self.onStare?(name, pet) }
            queue.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
            return
        }
        guard msg.type == .challenge,
              let fromName = msg.fromName,
              let fromPet = msg.fromPet else { return }
        // 세대가 다르면 시작하지 않는다. 구버전 상대는 그냥 "거절됨" 으로 보게 되는데,
        // 어긋난 승패를 양쪽에 띄우는 것보다는 낫다.
        guard msg.version == protocolVersion else {
            battleLog("incompatible challenger \(fromName) (version \(msg.version.map(String.init) ?? "none"))")
            conn.send(BattleMessage(type: .decline, version: protocolVersion))
            DispatchQueue.main.async { self.onIncompatiblePeer?(fromName) }
            queue.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
            return
        }
        let challengerPower = msg.power ?? 0

        // Ask the UI (main thread) whether to accept; respond back on our queue.
        DispatchQueue.main.async {
            let respond: (Bool) -> Void = { accepted in
                self.queue.async {
                    guard accepted else {
                        conn.send(BattleMessage(type: .decline))
                        // Give the decline a moment to flush, then drop it.
                        self.queue.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
                        return
                    }
                    let seed = UInt64.random(in: UInt64.min...UInt64.max)
                    let myPower = self.localPower?() ?? 0
                    // 결과는 여기서 한 번만 계산하고, 상대는 그것을 그대로 재생한다.
                    let outcome = simulateBattle(seed: seed,
                                                 powers: [.challenger: challengerPower,
                                                          .accepter: myPower])
                    conn.send(BattleMessage(type: .accept,
                                            version: self.protocolVersion,
                                            fromID: self.instanceID,
                                            fromName: self.displayName,
                                            fromPet: self.petSlug,
                                            seed: seed,
                                            outcome: outcome))
                    DispatchQueue.main.async {
                        self.onBattleStart?(.accepter, outcome, fromName, fromPet)
                    }
                    // Keep the connection alive briefly so the accept flushes,
                    // then let it close — the battle itself needs no more traffic.
                    self.queue.asyncAfter(deadline: .now() + 1.0) { conn.cancel() }
                }
            }
            self.onIncomingChallenge?(fromName, respond)
        }
    }

    // MARK: - Browser (discover peers)

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: battleServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updatePeers(from: results)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                battleLog("browser failed: \(err)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func updatePeers(from results: Set<NWBrowser.Result>) {
        var next: [String: BattlePeer] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let id = txt["id"], id != instanceID,   // skip ourselves
                  let name = txt["name"],
                  let pet = txt["pet"] else { continue }
            next[id] = BattlePeer(id: id, name: name, pet: pet, endpoint: result.endpoint)
        }
        peers = next
        let list = Array(next.values).sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.onPeersChanged?(list) }
    }

    // MARK: - Outbound (노려보기)

    /// `peer` 를 노려본다. 응답을 기다리지 않는다 — 보내고 잠시 뒤 연결을 닫는다.
    /// 상대 쪽에서는 확인 버튼 하나짜리 알림이 뜬다.
    func stare(at peer: BattlePeer) {
        queue.async {
            let nwConn = NWConnection(to: peer.endpoint, using: .tcp)
            let conn = BattleConnection(connection: nwConn, queue: self.queue)
            conn.onReady = { [weak conn] in
                conn?.send(BattleMessage(type: .stare,
                                         fromID: self.instanceID,
                                         fromName: self.displayName,
                                         fromPet: self.petSlug))
                // 보낸 뒤 플러시될 시간만 주고 닫는다.
                self.queue.asyncAfter(deadline: .now() + 0.5) { conn?.cancel() }
            }
            conn.start()
        }
    }

    // MARK: - Outbound (challenge a peer)

    /// Challenge `peer`. Dials a fresh connection, sends our challenge, and waits
    /// for `accept` (→ `onBattleStart`) or `decline`. `onResult` reports the
    /// terminal outcome so the UI can show "declined"/"no answer".
    func challenge(_ peer: BattlePeer, onResult: @escaping (ChallengeResult) -> Void) {
        queue.async {
            let nwConn = NWConnection(to: peer.endpoint, using: .tcp)
            let conn = BattleConnection(connection: nwConn, queue: self.queue)
            self.outgoing[peer.id] = conn

            var settled = false
            let finish: (ChallengeResult) -> Void = { result in
                guard !settled else { return }
                settled = true
                DispatchQueue.main.async { onResult(result) }
                self.queue.asyncAfter(deadline: .now() + 0.3) {
                    conn.cancel()
                    self.outgoing[peer.id] = nil
                }
            }

            let myPower = self.localPower?() ?? 0
            conn.onReady = { [weak conn] in
                conn?.send(BattleMessage(type: .challenge,
                                         version: self.protocolVersion,
                                         fromID: self.instanceID,
                                         fromName: self.displayName,
                                         fromPet: self.petSlug,
                                         power: myPower))
            }
            conn.onMessage = { msg in
                switch msg.type {
                case .accept:
                    // 결과를 보낼 줄 모르는 구버전이면 시작하지 않는다. 여기서 우리가
                    // 직접 계산하면 상대는 자기 규칙으로 이미 다른 승자를 띄운 뒤다.
                    guard msg.version == self.protocolVersion, let outcome = msg.outcome else {
                        battleLog("incompatible accepter (version \(msg.version.map(String.init) ?? "none"))")
                        finish(.incompatible)
                        return
                    }
                    DispatchQueue.main.async {
                        self.onBattleStart?(.challenger, outcome,
                                            msg.fromName ?? peer.name,
                                            msg.fromPet ?? peer.pet)
                    }
                    finish(.accepted)
                case .decline:
                    finish(.declined)
                case .challenge, .stare:
                    break // not expected inbound on the dialing side
                }
            }
            conn.onClose = { finish(.failed) }
            conn.start()

            // No answer in time → treat as failure so the UI doesn't hang.
            self.queue.asyncAfter(deadline: .now() + 15) { finish(.failed) }
        }
    }

    enum ChallengeResult {
        case accepted
        case declined
        case failed
        /// 상대 앱의 전투 규칙 세대가 달라 대전을 시작하지 않았다.
        case incompatible
    }
}

/// Length-prefixed JSON framing over a single `NWConnection`. Every message is
/// a 4-byte big-endian length followed by that many bytes of JSON. Handles both
/// directions the same way, so inbound (from the listener) and outbound (dialed)
/// connections share one implementation.
final class BattleConnection: Hashable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    var onReady: (() -> Void)?
    var onMessage: ((BattleMessage) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
                self?.receiveNext()
            case .failed, .cancelled:
                self?.onClose?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: BattleMessage) {
        guard let payload = try? JSONEncoder().encode(message) else { return }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.onClose?()
                return
            }
            self.receiveNext()
        }
    }

    /// Pull every complete `[len][payload]` frame out of the buffer.
    private func drainFrames() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            buffer.removeSubrange(0..<total)
            if let message = try? JSONDecoder().decode(BattleMessage.self, from: payload) {
                onMessage?(message)
            }
        }
    }

    static func == (lhs: BattleConnection, rhs: BattleConnection) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

func battleLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
        FileHandle.standardError.write("[connor-pet][battle] \(message())\n".data(using: .utf8)!)
    }
}
