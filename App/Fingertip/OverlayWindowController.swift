//
//  OverlayWindowController.swift
//  Fingertip
//
//  La franja en sí: una NSWindow borderless, click-through, anclada al borde
//  inferior de la pantalla principal. Vive siempre que haya al menos una
//  sesión abierta en `OverlayBeaconServer`.
//

import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var window: NSWindow?
    /// Whether the last call asked to show. A fade-out that ends after a newer `show` must not
    /// take the window off screen.
    private var isShown = false

    private init() {}

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func show() {
        isShown = true
        let window = window ?? makeWindow()
        self.window = window
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
    }

    private func hide() {
        isShown = false
        guard let window else { return }
        // The async form resumes on the main actor once the fade ends, where `orderOut` belongs.
        Task {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }
            guard !isShown else { return }
            window.orderOut(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let height: CGFloat = 28
        let frame = NSRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: height)

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: IndicatorShaderView())
        return window
    }
}
