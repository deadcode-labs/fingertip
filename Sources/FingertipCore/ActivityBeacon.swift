//
//  ActivityBeacon.swift
//  FingertipCore
//
//  The Fingertip app's view of an active session. The socket itself is the
//  "session open" signal: while the fd stays open the app shows its edge
//  indicator, and when it closes — on purpose or because the process died —
//  the OS notices without heartbeats or timeouts. The MCP keeps it open only
//  while a tool call runs and for `idleGrace` after the last one, so the edge
//  means "fingertip is acting", not "a Claude Code session has it connected". Over the same socket go
//  newline-delimited JSON `OverlayEvent`s (where the agent is acting, what it
//  is doing). All of it is cosmetic: if the app isn't running, or a write
//  fails, the event is dropped and the tool call never notices.
//

import CoreGraphics
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `sockaddr_un` for `path`, or `nil` if it doesn't fit in `sun_path`. Used both by
/// `ActivityBeacon` (the client, here) and by the server on the app side.
public nonisolated func unixSocketAddress(forPath path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        path.withCString { cString in
            buffer.copyBytes(from: UnsafeRawBufferPointer(start: cString, count: path.utf8.count + 1))
        }
    }
    return address
}

/// One line on the beacon socket.
public nonisolated enum OverlayEvent: Codable, Sendable, Equatable {
    /// First line of a connection that is a device session. Connections that only
    /// drop an event (the Claude Code hook, through `nc -U`) don't send it, so they
    /// don't count as a session. `owner` is the PID of the Claude Code process that
    /// spawned the MCP, so a `turn` from a hook can be matched to its session.
    case session(owner: Int32? = nil)
    /// About to act on `frame`, in global screen coordinates with the origin at the
    /// top-left of the main display (Quartz / Accessibility space). A zero-size frame
    /// is a bare point.
    case pointer(frame: CGRect, caption: String)
    /// What the agent is doing now, for the status toast.
    case status(text: String, state: OverlayStatus)
    /// A Claude Code turn started or ended (sent by a hook, not by fingertip). `owner`
    /// is the hook's `$PPID`, the Claude Code process, as in `session`; `nil` from an
    /// older hook that doesn't send it.
    case turn(ended: Bool, owner: Int32? = nil)
}

public nonisolated enum OverlayStatus: String, Codable, Sendable {
    /// A tool or a Jev step is running.
    case working
    /// A tool finished fine; the agent is back to thinking.
    case done
    case failed
    /// Stopped for the user: low confidence or a risky step.
    case held
    /// Jev judged the instruction done.
    case goal
}

public actor ActivityBeacon {
    public static let shared = ActivityBeacon()

    /// `~/Library/Application Support/fingertip/overlay.sock`, next to `settings.json`.
    public static let socketPath = URL.applicationSupportDirectory
        .appending(path: "fingertip/overlay.sock").path

    private var socket: Int32?
    /// The unsent tail of a line a write only got partly out. It goes before anything
    /// else, or the reader would see half a line glued to the next one.
    private var unsent = Data()
    /// A session was opened, so an event may reconnect: the app can start, or
    /// restart, after the MCP connected to a device.
    private var wantsConnection = false
    /// Tool calls running now.
    private var busy = 0
    private var idleTimer: Task<Void, Never>?
    /// How long the session stays open after the last call: long enough that the edge does not
    /// blink between the calls of one step, short enough that it is off while nothing happens.
    private static let idleGrace: Duration = .seconds(30)

    private init() {}

    /// A tool call starts: the session reopens if it had closed for idleness.
    public func beginActivity() {
        busy += 1
        idleTimer?.cancel()
        idleTimer = nil
        if wantsConnection { connectIfNeeded() }
    }

    /// A tool call ended: after `idleGrace` without another, the session closes and the app
    /// hides the edge.
    public func endActivity() {
        busy = max(0, busy - 1)
        guard busy == 0 else { return }
        idleTimer?.cancel()
        idleTimer = Task {
            try? await Task.sleep(for: Self.idleGrace)
            guard !Task.isCancelled else { return }
            self.closeIfIdle()
        }
    }

    private func closeIfIdle() {
        guard busy == 0 else { return }
        idleTimer = nil
        disconnect()
    }

    public func markActive() {
        wantsConnection = true
        connectIfNeeded()
    }

    public func send(_ event: OverlayEvent) {
        guard wantsConnection else { return }
        connectIfNeeded()
        write(event)
    }

    private func write(_ event: OverlayEvent) {
        guard socket != nil, var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A)
        // A tail still waiting means the reader is behind: drop this event whole rather than queue it.
        guard flush(), unsent.isEmpty else { return }
        unsent = line
        _ = flush()
    }

    /// Writes as much of `unsent` as the socket takes. Returns false if the socket was dropped.
    /// A full buffer (the app stalled) leaves the rest for the next event; a dead peer drops
    /// the socket, and the next event tries a fresh connection.
    @discardableResult
    private func flush() -> Bool {
        guard let fd = socket else { return false }
        while !unsent.isEmpty {
            let written = unsent.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                unsent.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                break
            } else {
                disconnect()
                return false
            }
        }
        return true
    }

    private func connectIfNeeded() {
        guard socket == nil else { return }
        guard var address = unixSocketAddress(forPath: Self.socketPath) else { return }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return
        }
        // Writing to a closed peer must fail with EPIPE, not kill the MCP with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Never block a tool call on a slow reader.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        socket = fd
        unsent = Data()
        write(.session(owner: getppid()))
    }

    private func disconnect() {
        guard let fd = socket else { return }
        close(fd)
        socket = nil
        unsent = Data()
    }
}
