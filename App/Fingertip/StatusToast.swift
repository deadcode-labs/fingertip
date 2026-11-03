//
//  StatusToast.swift
//  Fingertip
//
//  A small toast above the bottom edge of the main screen saying what the
//  agent is doing: the tool running, Jev's step, an error code, "Pensando…"
//  between calls. The MCP only sees tool calls, so "thinking" is inferred
//  (a call finished and the next hasn't started) and the end of a turn is
//  known only through the Claude Code `Stop` hook; without it the toast fades
//  after a while with nothing happening, instead of claiming "Listo".
//

import AppKit
import FingertipCore
import Observation
import SwiftUI

@MainActor
final class StatusToast {
    static let shared = StatusToast()

    private let model = ToastModel()
    private var window: NSWindow?
    private var thinkingTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// Bumped by every `scheduleHide`, so a fade-out that finishes after a newer
    /// event arrived leaves the toast up.
    private var hideGeneration = 0
    /// The Claude Code process whose session the toast is speaking for, so the end of
    /// another session's turn doesn't claim "Listo" over it.
    private var owner: Int32?

    /// After a call finishes, how long before the toast says the agent is thinking.
    private static let thinkingDelay: Duration = .milliseconds(800)
    /// Nothing heard for this long: the agent is probably done, but without the hook it can't be told.
    private static let idleTimeout: Duration = .seconds(45)
    private static let doneLingering: Duration = .seconds(4)

    private init() {}

    /// `sender` is the owner of the session the event came over, `nil` for a bare connection.
    func handle(_ event: OverlayEvent, from sender: Int32?) {
        switch event {
        case .status(let text, let state):
            owner = sender
            show(text, state.toastState)
            thinkingTask?.cancel()
            if state == .done {
                thinkingTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.thinkingDelay)
                    guard !Task.isCancelled else { return }
                    self?.show("Pensando…", .thinking)
                }
            }
            scheduleHide(after: Self.idleTimeout)
        case .turn(let ended, let turnOwner):
            // Turns come from every Claude Code session with the hook; only one that
            // used fingertip, so its toast is up, gets a "Listo" — and with two of them
            // at once, only the one the toast speaks for. A hook or MCP too old to send
            // an owner can't be told apart, and still ends it.
            guard ended, model.isVisible else { return }
            if let turnOwner, let owner, turnOwner != owner { return }
            thinkingTask?.cancel()
            show("Listo", .finished)
            scheduleHide(after: Self.doneLingering)
        case .session, .pointer:
            break
        }
    }

    private func show(_ text: String, _ state: ToastState) {
        withAnimation(.snappy(duration: 0.2)) {
            model.text = text
            model.state = state
        }
        if model.isVisible {
            // Still up, but maybe halfway through fading out: bring it back.
            if let window { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window.animator().alphaValue = 1 } }
            return
        }
        model.isVisible = true
        let window = self.window ?? makeWindow()
        self.window = window
        place(window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window.animator().alphaValue = 1 }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideGeneration += 1
        let generation = hideGeneration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let window = self.window else { return }
            self.thinkingTask?.cancel()
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }, completionHandler: {
                Task { @MainActor in
                    guard self.hideGeneration == generation else { return }
                    window.orderOut(nil)
                    self.model.isVisible = false
                }
            })
        }
    }

    /// Centered on the main screen, just above the edge indicator.
    private func place(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = CGSize(width: 640, height: 56)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 40)
        window.setFrame(CGRect(origin: origin, size: size), display: false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ToastView(model: model))
        return window
    }
}

enum ToastState {
    case working, thinking, failed, held, goal, finished
}

private extension OverlayStatus {
    var toastState: ToastState {
        switch self {
        case .working, .done: .working
        case .failed: .failed
        case .held: .held
        case .goal: .goal
        }
    }
}

@MainActor
@Observable
final class ToastModel {
    var text = ""
    var state: ToastState = .working
    var isVisible = false
}

private struct ToastView: View {
    let model: ToastModel

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var tint: Color {
        switch model.state {
        case .working, .thinking: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .failed: .red
        case .held: .orange
        case .goal, .finished: .green
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.state {
        case .working:
            ProgressView().controlSize(.small)
        case .thinking:
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(tint)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
        case .held:
            Image(systemName: "hand.raised.fill").foregroundStyle(tint)
        case .goal, .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
        }
    }
}
