//
//  Delivery.swift
//  FingertipCore
//
//  What an action did, strategy by strategy. An Accessibility call that returns
//  success only says the app took the request: `AXPress` on a row can succeed and
//  select nothing, and on a toolbar button it can succeed and open nothing. The
//  driver reads back what it can and reports each step, so "done" means done.
//

import CoreGraphics
import Foundation

/// One strategy tried while acting on an element, and what came of it.
public nonisolated struct DeliveryStep: Hashable, Sendable {
    public enum Outcome: String, Hashable, Sendable {
        /// The app refused it or it does not apply here: nothing happened.
        case notDelivered = "not_delivered"
        /// The app took it, and what it should have changed did not change.
        case noEffect = "no_effect"
        /// The app took it, and there is nothing to read back to confirm it.
        case delivered
        /// The app took it, and the expected change was read back.
        case verified

        /// Whether the strategies after this one should still run.
        public var tryNext: Bool { self == .notDelivered || self == .noEffect }

        /// Emitted to the MCP outline.
        public var caption: String {
            switch self {
            case .notDelivered: "not delivered"
            case .noEffect: "no effect"
            case .delivered: "delivered"
            case .verified: "verified"
            }
        }
    }

    /// The Accessibility call or the fallback, e.g. `AXPress`, `AXSelected`, `click`.
    public var strategy: String
    public var outcome: Outcome
    /// What was read back, or why it was not delivered.
    public var detail: String?

    public init(_ strategy: String, _ outcome: Outcome, _ detail: String? = nil) {
        self.strategy = strategy
        self.outcome = outcome
        self.detail = detail
    }

    public var caption: String {
        detail.map { "\(strategy) \(outcome.caption) (\($0))" } ?? "\(strategy) \(outcome.caption)"
    }
}

/// A window of the Mac app under test, as `list_windows` shows it.
public nonisolated struct WindowInfo: Hashable, Sendable {
    /// The window server's number: stable while the window lives, unique across apps.
    public var number: Int
    public var title: String
    /// Global screen coordinates, top-left origin.
    public var frame: CGRect
    public var isFocused: Bool
    public var isMinimized: Bool
    /// The window reads and actions go to, when one was chosen.
    public var isChosen: Bool
    /// On a Space not on screen: listed by the window server, out of AX's reach unless it is the
    /// app's focused window.
    public var isOnOtherSpace: Bool

    public init(
        number: Int, title: String, frame: CGRect, isFocused: Bool, isMinimized: Bool, isChosen: Bool,
        isOnOtherSpace: Bool = false
    ) {
        self.number = number
        self.title = title
        self.frame = frame
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.isChosen = isChosen
        self.isOnOtherSpace = isOnOtherSpace
    }

    /// `#4312 «Desktop — Local»`: how errors and listings name it.
    public var caption: String {
        "#\(number) «\(title.isEmpty ? "untitled" : title)»"
    }
}
