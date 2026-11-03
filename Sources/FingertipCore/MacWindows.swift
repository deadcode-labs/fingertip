//
//  MacWindows.swift
//  FingertipCore
//
//  Which window of the app the driver reads and acts on. With several open it
//  must be chosen explicitly: with two Finder windows open, "the focused one"
//  depends on what the user clicked last, and an agent reading one while
//  thinking it reads the other acts on the wrong folder.
//
//  A window is identified by the window server's number plus the process start
//  time. The number alone is unique only while the process lives.
//
//  `AXWindows` only lists windows on the Spaces on screen. The others are found
//  through the window server, so they count towards a choice and can be named,
//  but AX reaches only the app's focused one: the rest must be brought over.
//

import AppKit
import ApplicationServices

/// The window server's number for an AX window. Private, but stable since 10.5 and the only
/// link between an `AXUIElement` window and the `CGWindowID` ScreenCaptureKit uses.
@_silgen_name("_AXUIElementGetWindow")
nonisolated private func axWindowNumber(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The Spaces a window is on. Private (SkyLight), and what tells a window on another Space,
/// which is on one, from an inactive tab, which is on none: to the public window list both are
/// titled, off screen and missing from `AXWindows`.
@_silgen_name("CGSCopySpacesForWindows")
nonisolated private func cgsCopySpaces(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSMainConnectionID")
nonisolated private func cgsMainConnection() -> Int32

extension MacDriver {
    /// Subroles of a window the user works in; panels, dialogs and the like do not count
    /// towards an ambiguity.
    private static let documentSubroles: Set<String> = ["AXStandardWindow"]
    /// A window that blocks the app until answered: it wins over the chosen window, or the
    /// agent could never see the alert it is stuck on.
    private static let modalSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    static func windowNumber(_ window: AXUIElement) -> CGWindowID? {
        var number: CGWindowID = 0
        guard axWindowNumber(window, &number) == .success, number != 0 else { return nil }
        return number
    }

    /// The window to read: a modal dialog of the app if one is up, else the chosen window,
    /// else the focused one. With several document windows, counting those on other Spaces,
    /// there is no default.
    ///
    /// A chosen window that is gone is forgotten (`windowGone`), unless `forgetGone` is false:
    /// a check made while an action runs must leave that to the reading after it, which is
    /// where the caller learns of it.
    func targetWindow(root: AXUIElement, app: NSRunningApplication, forgetGone: Bool = true) throws -> AXUIElement {
        let windows: [AXUIElement] = Self.attribute(root, "AXWindows") ?? []
        let focused: AXUIElement? = Self.attribute(root, "AXFocusedWindow")
        if let focused, let subrole: String = Self.attribute(focused, "AXSubrole"), Self.modalSubroles.contains(subrole) {
            return focused
        }

        if let chosen = chosenWindow {
            guard Self.processStart(app.processIdentifier) == chosen.processStart else {
                if forgetGone { chosenWindow = nil }
                throw MacDriverError.windowGone("la app se reinició")
            }
            if let window = Self.reachable(chosen.number, windows: windows, root: root) { return window }
            // Still open, on a Space AX does not reach: the choice stands for when it comes back.
            if let elsewhere = otherSpaceWindows(app: app, listed: windows, focused: nil)
                .first(where: { $0.number == Int(chosen.number) }) {
                throw MacDriverError.windowOnOtherSpace(elsewhere)
            }
            if forgetGone { chosenWindow = nil }
            throw MacDriverError.windowGone("se cerró la #\(chosen.number)")
        }

        let documents = windows.filter(Self.isOpenDocumentWindow)
        // Past one window the choice is needed anyway: no need to ask the window server.
        let focusedNumber = focused.flatMap(Self.windowNumber)
        let elsewhere = documents.count > 1 ? [] : otherSpaceWindows(app: app, listed: windows, focused: focusedNumber)
        if documents.count + elsewhere.count > 1 {
            throw MacDriverError.ambiguousWindow(
                app: app.localizedName ?? bundleID,
                windows: documents.compactMap { info(of: $0, focused: focusedNumber) } + elsewhere
            )
        }
        guard let window = Self.window(of: root) else { throw MacDriverError.noWindow(bundleID) }
        return window
    }

    func listWindows() async throws -> [WindowInfo] {
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let windows: [AXUIElement] = Self.attribute(root, "AXWindows") ?? []
        let focused = (Self.attribute(root, "AXFocusedWindow") as AXUIElement?).flatMap(Self.windowNumber)
        return windows.compactMap { info(of: $0, focused: focused) }
            + otherSpaceWindows(app: app, listed: windows, focused: focused)
    }

    func chooseWindow(number: Int) async throws {
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let windows: [AXUIElement] = Self.attribute(root, "AXWindows") ?? []
        guard Self.reachable(CGWindowID(number), windows: windows, root: root) != nil else {
            if let elsewhere = otherSpaceWindows(app: app, listed: windows, focused: nil)
                .first(where: { $0.number == number }) {
                throw MacDriverError.windowOnOtherSpace(elsewhere)
            }
            throw MacDriverError.unknownWindow(number)
        }
        guard let start = Self.processStart(app.processIdentifier) else { throw MacDriverError.unknownWindow(number) }
        chosenWindow = (CGWindowID(number), start)
        // Aliases and the open menus belonged to the window read before.
        elements = [:]
        openMenus = []
        focusedText = nil
    }

    /// The AX window with that number: listed, or the app's focused or main window, which AX
    /// still hands out when it sits on another Space.
    private static func reachable(_ number: CGWindowID, windows: [AXUIElement], root: AXUIElement) -> AXUIElement? {
        if let listed = windows.first(where: { windowNumber($0) == number }) { return listed }
        return ["AXFocusedWindow", "AXMainWindow"].lazy
            .compactMap { (attribute(root, $0) as AXUIElement?) }
            .first { windowNumber($0) == number }
    }

    /// The app's windows on Spaces not on screen, which `AXWindows` leaves out: titled windows
    /// of the app on the normal layer, missing from `listed`, and on some Space (an inactive tab
    /// is on none). Titles need Screen Recording; without it nothing is found.
    private func otherSpaceWindows(app: NSRunningApplication, listed: [AXUIElement], focused: CGWindowID?) -> [WindowInfo] {
        let pid = app.processIdentifier
        let known = Set(listed.compactMap(Self.windowNumber))
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates: [(number: CGWindowID, title: String, frame: CGRect)] = all.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let title = window[kCGWindowName as String] as? String, !title.isEmpty,
                  let number = window[kCGWindowNumber as String] as? CGWindowID, !known.contains(number)
            else { return nil }
            let frame = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            return (number, title, frame ?? .zero)
        }
        guard !candidates.isEmpty else { return [] }
        let connection = cgsMainConnection()
        return candidates.compactMap { window in
            // 7: every kind of Space (user, full screen, system).
            let spaces = cgsCopySpaces(connection, 7, [window.number] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
            guard !spaces.isEmpty else { return nil }
            return WindowInfo(
                number: Int(window.number),
                title: window.title,
                frame: window.frame,
                isFocused: focused == window.number,
                isMinimized: false,
                isChosen: chosenWindow?.number == window.number,
                isOnOtherSpace: true
            )
        }
    }

    private static func isOpenDocumentWindow(_ window: AXUIElement) -> Bool {
        let subrole: String? = attribute(window, "AXSubrole")
        let minimized: Bool = attribute(window, "AXMinimized") ?? false
        return subrole.map(documentSubroles.contains) == true && !minimized
    }

    private func info(of window: AXUIElement, focused: CGWindowID?) -> WindowInfo? {
        guard let number = Self.windowNumber(window) else { return nil }
        let node = Self.read(window)
        return WindowInfo(
            number: Int(number),
            title: node.title ?? "",
            frame: node.frame ?? .zero,
            isFocused: focused == number,
            isMinimized: Self.attribute(window, "AXMinimized") ?? false,
            isChosen: chosenWindow?.number == number
        )
    }
}
