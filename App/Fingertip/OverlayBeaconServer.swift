//
//  OverlayBeaconServer.swift
//  Fingertip
//
//  Server end of the socket `ActivityBeacon` opens in FingertipCore. A
//  connection that starts with `OverlayEvent.session` is an active session (a
//  `fingertip-mcp` acting on a device); the edge indicator shows while at
//  least one is awake and hides when the last one closes — on purpose, as the
//  MCP does a while after its last tool call, or because the process died,
//  which closes the fd all the same. A session also sleeps when the Claude Code
//  turn behind it ends (the Stop hook's `turn`), and wakes with its next event.
//  Other connections only drop events, like the hook through `nc -U`.
//

import Darwin
import FingertipCore
import Foundation

actor OverlayBeaconServer {
    static let shared = OverlayBeaconServer()

    private var listenSocket: Int32?

    private init() {}

    func start() {
        guard listenSocket == nil else { return }

        let path = ActivityBeacon.socketPath
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path) // stale socket from an earlier crash

        guard var address = unixSocketAddress(forPath: path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        listenSocket = fd
        Thread.detachNewThread { [self] in
            Self.acceptLoop(listenSocket: fd, server: self)
        }
    }

    /// Blocking: runs on its own `Thread`, not on the cooperative pool. Transient failures
    /// (a peer that gave up before being accepted, a signal, running out of descriptors for
    /// a moment) don't end it; only a listener that is gone does.
    private nonisolated static func acceptLoop(listenSocket: Int32, server: OverlayBeaconServer) {
        while true {
            let clientSocket = accept(listenSocket, nil, nil)
            guard clientSocket >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    usleep(100_000)
                    continue
                default:
                    return // EBADF, EINVAL: the listener closed
                }
            }
            Thread.detachNewThread {
                readEvents(from: clientSocket)
                close(clientSocket)
            }
        }
    }

    /// Longest line accepted. Real events are a few hundred bytes; a peer that sends more
    /// without a newline is not speaking this protocol, and its connection is closed.
    private nonisolated static let maxLineLength = 64 * 1024

    /// Blocking until the peer closes. Each line is an `OverlayEvent`; a line that doesn't
    /// decode (a newer or older MCP) is skipped.
    ///
    /// Every event, from every connection, reaches the main actor through the main queue,
    /// which runs them in the order they were read: a session's close can't overtake its
    /// open, nor a pointer the one before it, as independent `Task`s could.
    private nonisolated static func readEvents(from socket: Int32) {
        var isSession = false
        var owner: Int32? // the Claude Code process behind the session, to match its `turn`s
        let connection = socket
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer {
            if isSession { deliver { OverlaySessions.shared.closed(connection) } }
        }
        while true {
            let count = read(socket, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending[lineStart..<newline]
                lineStart = newline + 1
                guard let event = try? JSONDecoder().decode(OverlayEvent.self, from: line) else { continue }
                switch event {
                case .session(let sessionOwner):
                    if !isSession {
                        isSession = true
                        owner = sessionOwner
                        let sessionOwner = owner
                        deliver { OverlaySessions.shared.opened(connection, owner: sessionOwner) }
                    }
                case .pointer:
                    if isSession { deliver { OverlaySessions.shared.woke(connection) } }
                    deliver { PointerOverlay.shared.handle(event) }
                case .status:
                    if isSession { deliver { OverlaySessions.shared.woke(connection) } }
                    let owner = owner
                    deliver { StatusToast.shared.handle(event, from: owner) }
                case .turn(let ended, let turnOwner):
                    if ended { deliver { OverlaySessions.shared.turnEnded(owner: turnOwner) } }
                    let owner = owner
                    deliver { StatusToast.shared.handle(event, from: owner) }
                }
            }
            pending.removeSubrange(pending.startIndex..<lineStart)
            guard pending.count <= maxLineLength else { return }
        }
    }

    private nonisolated static func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

/// Open device sessions, tracked on the main actor in the order their events arrive. The edge
/// shows while any is awake: open, and not past the end of its Claude Code turn.
@MainActor
final class OverlaySessions {
    static let shared = OverlaySessions()

    /// By connection fd: the Claude Code process behind it, and whether it is awake.
    private var sessions: [Int32: (owner: Int32?, awake: Bool)] = [:]

    private init() {}

    func opened(_ connection: Int32, owner: Int32?) {
        sessions[connection] = (owner, true)
        update()
    }

    func closed(_ connection: Int32) {
        sessions[connection] = nil
        update()
    }

    /// The session acted again after its turn ended: a new turn has started.
    func woke(_ connection: Int32) {
        guard let session = sessions[connection], !session.awake else { return }
        sessions[connection] = (session.owner, true)
        update()
    }

    /// The Stop hook said a turn ended: that Claude Code session's fingertip is idle. A hook
    /// without an owner can't be matched, so it puts every session to sleep.
    func turnEnded(owner: Int32?) {
        for (connection, session) in sessions where owner == nil || session.owner == nil || session.owner == owner {
            sessions[connection] = (session.owner, false)
        }
        update()
    }

    private var visible = false

    /// Only on a change: showing again restarts the edge's fade-in.
    private func update() {
        let awake = sessions.values.contains { $0.awake }
        guard awake != visible else { return }
        visible = awake
        OverlayWindowController.shared.setVisible(awake)
    }
}
