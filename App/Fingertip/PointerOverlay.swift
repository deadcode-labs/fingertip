//
//  PointerOverlay.swift
//  Fingertip
//
//  A ghost pointer that shows where the agent is acting. fingertip acts through
//  Accessibility and never moves the real cursor, so without this a tap in a
//  background app is invisible. The pointer glides to each acted element,
//  outlines it, pulses, and fades out once the agent stops acting. It lives in
//  a borderless, click-through window covering the screen the element is on.
//

import AppKit
import FingertipCore
import Observation
import SwiftUI

@MainActor
final class PointerOverlay {
    static let shared = PointerOverlay()

    private let model = PointerModel()
    private var window: NSWindow?
    private var screenFrame: CGRect?
    private var hideTask: Task<Void, Never>?
    /// Bumped by every `scheduleHide`, so a fade-out that finishes after a newer
    /// pointer arrived leaves the window up.
    private var hideGeneration = 0
    private static let lingering: Duration = .seconds(2.5)

    private init() {}

    func handle(_ event: OverlayEvent) {
        switch event {
        case .pointer(let frame, let caption):
            point(at: frame, caption: caption)
        case .session, .status, .turn:
            break
        }
    }

    private func point(at globalFrame: CGRect, caption: String) {
        guard let primary = NSScreen.screens.first else { return }
        // Accessibility measures from the top-left of the main display, AppKit from its bottom-left.
        let flipped = CGRect(
            x: globalFrame.minX, y: primary.frame.maxY - globalFrame.maxY,
            width: globalFrame.width, height: globalFrame.height
        )
        let center = CGPoint(x: flipped.midX, y: flipped.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? primary
        // SwiftUI inside the window measures from the window's top-left again.
        let local = CGRect(
            x: flipped.minX - screen.frame.minX, y: screen.frame.maxY - flipped.maxY,
            width: flipped.width, height: flipped.height
        )

        let window = window(on: screen.frame)
        // Glide only from a pointer that is on screen, on this same display.
        model.move(to: local, caption: caption, glide: model.isVisible)
        if !model.isVisible {
            model.isVisible = true
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 1 }
        } else {
            // Still up, but maybe halfway through fading out: bring it back.
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 1 }
        }
        scheduleHide()
    }

    private func window(on frame: CGRect) -> NSWindow {
        if let window, screenFrame == frame { return window }
        // A different display: start over there instead of gliding across screens.
        model.isVisible = false
        screenFrame = frame
        if let window {
            window.setFrame(frame, display: false)
            return window
        }
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PointerView(model: model))
        window.setFrame(frame, display: false)
        self.window = window
        return window
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideGeneration += 1
        let generation = hideGeneration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lingering)
            guard !Task.isCancelled, let self, let window = self.window else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }, completionHandler: {
                Task { @MainActor in
                    guard self.hideGeneration == generation else { return }
                    window.orderOut(nil)
                    self.model.isVisible = false
                }
            })
        }
    }
}

@MainActor
@Observable
final class PointerModel {
    var target: CGRect = .zero
    var caption = ""
    var isVisible = false
    /// Bumped on every action, to restart the pulse.
    var pulse = 0

    func move(to target: CGRect, caption: String, glide: Bool) {
        self.caption = caption
        if glide {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { self.target = target }
        } else {
            self.target = target
        }
        pulse += 1
    }
}

private struct PointerView: View {
    let model: PointerModel
    private let tint = Color(red: 0.55, green: 0.36, blue: 0.96)

    var body: some View {
        let target = model.target
        let tip = CGPoint(x: target.midX, y: target.midY)

        ZStack(alignment: .topLeading) {
            if !target.size.equalTo(.zero) {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
                    .frame(width: target.width + 8, height: target.height + 8)
                    .position(x: target.midX, y: target.midY)
            }

            Pulse(trigger: model.pulse, tint: tint)
                .position(tip)

            ArrowShape()
                .fill(tint)
                .stroke(.white, lineWidth: 1.5)
                .frame(width: 14, height: 21)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                // The shape's tip is its top-left corner.
                .position(x: tip.x + 7, y: tip.y + 10.5)

            Text(model.caption)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint))
                .fixedSize()
                .offset(x: tip.x + 16, y: tip.y + 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct Pulse: View {
    let trigger: Int
    let tint: Color

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 2)
            .frame(width: 36, height: 36)
            .keyframeAnimator(initialValue: PulseFrame(), trigger: trigger) { content, frame in
                content.scaleEffect(frame.scale).opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.3, duration: 0.3)
                    CubicKeyframe(1.6, duration: 0.5)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 0.3)
                    LinearKeyframe(0.9, duration: 0.01)
                    CubicKeyframe(0, duration: 0.5)
                }
            }
    }
}

private nonisolated struct PulseFrame {
    var scale = 0.3
    var opacity = 0.0
}

/// A classic arrow cursor with its tip at the top-left corner of its frame.
private nonisolated struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [
            (0, 0), (0, 17), (4.5, 13), (7.5, 20), (10, 19), (7, 12.5), (12.5, 12.5),
        ].map { CGPoint(x: $0.0 / 12.5 * rect.width, y: $0.1 / 20 * rect.height) }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}
