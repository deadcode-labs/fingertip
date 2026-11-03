//
//  MacActions.swift
//  FingertipCore
//
//  How MacDriver acts on an element: a ladder from the most semantic call to a
//  real click, where every step that has something to check reads it back. An
//  Accessibility call answers whether the app took the request, not whether it
//  did anything, and both of these were measured on macOS 27:
//
//  - `AXPress` on Calculator's "Mode" toolbar button returns success and opens
//    nothing; so does `AXShowMenu`. Only a real click opens that menu.
//  - Setting `AXSelected` on a Reminders section row returns success and the
//    row stays unselected.
//
//  So a step reports one of four outcomes (`DeliveryStep.Outcome`), and only
//  "not delivered" and "no effect" let the next step run.
//

import AppKit
import ApplicationServices

extension MacDriver {
    /// How long a step waits for its effect (a menu, a selection, a checkbox) to show.
    private static let effectTimeout: Duration = .milliseconds(600)
    /// How long a real click waits for its effect; the click itself already waited for the
    /// window to be in front (`bringForward`).
    private static let clickTimeout: Duration = .milliseconds(1500)

    /// AX errors that mean the call never reached the app's handler, so nothing happened and
    /// trying again (or trying something else) is harmless. A timeout (`cannotComplete`) or a
    /// generic `failure` may have run halfway.
    nonisolated static func neverRan(_ error: AXError) -> Bool {
        switch error {
        case .actionUnsupported, .attributeUnsupported, .parameterizedAttributeUnsupported,
             .illegalArgument, .invalidUIElement, .invalidUIElementObserver,
             .notImplemented, .noValue, .apiDisabled:
            true
        default:
            false
        }
    }

    // MARK: - Tap

    /// From the most semantic to the most physical: focus a field, open a menu, press, open,
    /// activate the twin control inside, climb to the row that holds it and, if none of that
    /// had an effect, a real click. A menu-bar menu is not pressed: it is expanded or collapsed.
    func tap(_ element: AXUIElement, alias: Int, expanded: String?) async throws -> [DeliveryStep] {
        let node = Self.read(element)
        // With no role the element no longer exists: the view that held it is gone.
        guard !node.role.isEmpty else { throw MacDriverError.staleAlias(alias) }
        if node.role == "AXMenuBarItem" {
            expandedMenu = node.title == expanded ? nil : node.title
            return []
        }
        if Self.textRoles.contains(node.role) && node.role != "AXStaticText" {
            try Self.set(element, "AXFocused", true as CFBoolean)
            focusedText = element
            let focused: Bool = Self.attribute(element, "AXFocused") ?? false
            return [DeliveryStep("AXFocused", focused ? .verified : .delivered)]
        }
        let caption = Self.name(of: node)
        // A control whose menu is open closes it on a second tap, pop-up or toolbar button alike.
        if Self.menuRoles.contains(node.role) || Self.menu(of: element) != nil {
            return try await toggleMenu(of: element, owner: caption)
        }

        let actions = Self.actions(of: element)
        var steps: [DeliveryStep] = []

        if actions.contains("AXPress") {
            if actions.contains("AXShowMenu"), Self.isInToolbar(element) {
                return try await pressToolbarButton(element, owner: caption)
            }
            let step = try await press(element, role: node.role, label: "AXPress")
            steps.append(step)
            if !step.outcome.tryNext { return steps }
        }
        if actions.contains("AXOpen") {
            let step = try await deliverStep("AXOpen", to: element, label: "AXOpen")
            steps.append(step)
            if !step.outcome.tryNext { return steps }
        }
        if let step = try await activateTwin(of: element, node: node) {
            steps.append(step)
            return steps
        }

        // A text inside a row (Finder, AppKit tables): the cell that opens, the ancestor that
        // presses or the row that selects, in that order at each level.
        var ancestor: AXUIElement? = Self.attribute(element, "AXParent")
        for _ in 0..<4 {
            guard let current = ancestor else { break }
            let role: String = Self.attribute(current, "AXRole") ?? ""
            let where_ = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            let ancestorActions = Self.actions(of: current)
            if ancestorActions.contains("AXPress") {
                let step = try await press(current, role: role, label: "AXPress (\(where_))")
                steps.append(step)
                if !step.outcome.tryNext { return steps }
            }
            // A Finder sidebar cell: AXOpen navigates, where selecting the row only highlights it.
            if ancestorActions.contains("AXOpen") {
                let step = try await deliverStep("AXOpen", to: current, label: "AXOpen (\(where_))")
                steps.append(step)
                if !step.outcome.tryNext { return steps }
            }
            if role == "AXRow" {
                let step = try await selectRow(current)
                steps.append(step)
                if !step.outcome.tryNext { return steps }
            }
            ancestor = Self.attribute(current, "AXParent")
        }

        guard let frame = node.frame, !frame.isEmpty else {
            if steps.contains(where: { $0.outcome == .noEffect }) {
                throw MacDriverError.noEffect("«\(caption)»", steps)
            }
            throw MacDriverError.axFailed("tocar \(caption)", .noValue)
        }
        try await click(at: CGPoint(x: frame.midX, y: frame.midY))
        steps.append(DeliveryStep("clic", .delivered))
        return steps
    }

    /// `AXPress`, and inside a row, its effect read back. AppKit grids answer success to a press
    /// on a row that selects nothing, and a SwiftUI row's button can do the same. So a press in
    /// a row counts if the row got selected (verified) or the window changed (delivered); if
    /// neither, it had no effect and the next strategy selects the row instead. A row that was
    /// already selected proves nothing, so then only a change in the window counts.
    private func press(_ element: AXUIElement, role: String, label: String) async throws -> DeliveryStep {
        let row = role == "AXRow" ? element : Self.enclosingRow(of: element)
        let wasSelected = row.flatMap(Self.selection(of:))
        // The window just before the press, as in `pressToolbarButton` and `openMenu`; `deliver`
        // compares against the same one.
        let baseline = fingerprint()
        let answer = try await deliver("AXPress", to: element, baseline: baseline)
        guard answer.ran else { return DeliveryStep(label, .notDelivered, answer.detail) }
        guard let row, wasSelected != nil else { return DeliveryStep(label, .delivered, answer.detail) }
        var changed = false
        let selected = await poll {
            if wasSelected == false, Self.selection(of: row) == true { return true }
            changed = fingerprint() != baseline
            return changed
        }
        if selected && !changed { return DeliveryStep(label, .verified, "fila seleccionada") }
        if changed { return DeliveryStep(label, .delivered, answer.detail ?? "la ventana cambió") }
        return DeliveryStep(label, .noEffect, wasSelected == true ? "la fila ya estaba seleccionada y nada cambió" : "la fila sigue sin seleccionar y nada cambió")
    }

    private func selectRow(_ row: AXUIElement) async throws -> DeliveryStep {
        let label = "AXSelected (Row)"
        guard Self.isSettable(row, "AXSelected") else { return DeliveryStep(label, .notDelivered, "no se puede seleccionar") }
        // Selecting a selected row changes nothing, and reading it back would verify anything.
        if Self.selection(of: row) == true { return DeliveryStep(label, .notDelivered, "ya estaba seleccionada") }
        let result = AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue)
        guard result == .success else {
            if Self.neverRan(result) { return DeliveryStep(label, .notDelivered, "AXError \(result.rawValue)") }
            throw MacDriverError.axFailed("AXSelected", result)
        }
        return await poll { Self.selection(of: row) == true }
            ? DeliveryStep(label, .verified, "fila seleccionada")
            : DeliveryStep(label, .noEffect, "la fila sigue sin seleccionar")
    }

    /// SwiftUI often exposes one control twice: a named wrapper with no action around the
    /// element that has it. Only a child with the same name is activated, never another
    /// control of the row ("Delete", "Add list"): that is not what a tap on the row means.
    private func activateTwin(of element: AXUIElement, node: Node) async throws -> DeliveryStep? {
        let names = Set([node.title, node.description, node.value].compactMap { $0 })
        guard !names.isEmpty else { return nil }
        for child in node.children.prefix(5) {
            let twin = Self.read(child)
            guard [twin.title, twin.description, twin.value].contains(where: { $0.map(names.contains) == true }) else { continue }
            let actions = Self.actions(of: child)
            for action in ["AXPress", "AXOpen"] where actions.contains(action) {
                let answer = try await deliver(action, to: child)
                if answer.ran { return DeliveryStep("\(action) (hijo)", .delivered, answer.detail) }
            }
        }
        return nil
    }

    // MARK: - Menus

    /// A tap on a pop-up: opens its menu, or closes it if it is the one open, as a second click
    /// would. Another control's open menu is refused: two menus would stack, and the second
    /// keeps the first from closing.
    private func toggleMenu(of control: AXUIElement, owner: String) async throws -> [DeliveryStep] {
        if let menu = Self.menu(of: control) {
            let step = try await deliverStep("AXCancel", to: menu, label: "AXCancel")
            guard step.outcome != .notDelivered else { return [step] }
            return await poll { Self.menu(of: control) == nil }
                ? [DeliveryStep("AXCancel", .verified, "menú cerrado")]
                : [DeliveryStep("AXCancel", .noEffect, "el menú sigue abierto")]
        }
        if let open = liveOpenMenu() { throw MacDriverError.menuAlreadyOpen(open.owner) }
        return try await openMenu(of: control, owner: owner, actions: ["AXPress", "AXShowMenu"])
    }

    /// A toolbar button that advertises a menu may be a plain button ("Show Sidebar") or a
    /// menu ("Mode"), and AX tells them apart in nothing. So it is pressed, and only if neither
    /// a menu nor anything in the window changed is it treated as a menu and opened with a
    /// click. The effect must show within 600 ms; a slower button gets clicked again.
    private func pressToolbarButton(_ button: AXUIElement, owner: String) async throws -> [DeliveryStep] {
        if let open = liveOpenMenu() { throw MacDriverError.menuAlreadyOpen(open.owner) }
        let before = fingerprint()
        let answer = try await deliver("AXPress", to: button)
        guard answer.ran else {
            return try await openMenu(of: button, owner: owner, actions: ["AXShowMenu"], after: [DeliveryStep("AXPress", .notDelivered, answer.detail)])
        }
        var changed = false
        let opened = await poll {
            if Self.menu(of: button) != nil { return true }
            changed = fingerprint() != before
            return changed
        }
        if opened && !changed { return [DeliveryStep("AXPress", .verified, "menú abierto")] }
        if changed { return [DeliveryStep("AXPress", .delivered)] }
        return try await openMenu(of: button, owner: owner, actions: ["AXShowMenu"], after: [DeliveryStep("AXPress", .noEffect)])
    }

    /// Opens the control's menu with each action in turn and then a real click, until the menu
    /// shows up as the control's child. Each step waits for it first, so a menu that opens late
    /// is not opened a second time on top.
    ///
    /// The click is the only way to open some menu buttons (Calculator's "Mode"), and on a
    /// plain button it runs the button. So a click that opens no menu but changes the window
    /// is reported as having run, and a menu that shows up after giving up is cancelled.
    private func openMenu(of control: AXUIElement, owner: String, actions: [String], after earlier: [DeliveryStep] = []) async throws -> [DeliveryStep] {
        var steps = earlier
        let available = Self.actions(of: control)
        for action in actions where available.contains(action) {
            let answer = try await deliver(action, to: control)
            guard answer.ran else {
                steps.append(DeliveryStep(action, .notDelivered, answer.detail))
                continue
            }
            if await poll({ Self.menu(of: control) != nil }) {
                steps.append(DeliveryStep(action, .verified, "menú abierto"))
                return steps
            }
            steps.append(DeliveryStep(action, .noEffect))
        }
        if let frame = Self.read(control).frame, !frame.isEmpty {
            let before = fingerprint()
            if try await clickVerified(frame, until: { Self.menu(of: control) != nil }) {
                steps.append(DeliveryStep("clic", .verified, "menú abierto"))
                return steps
            }
            steps.append(fingerprint() != before
                ? DeliveryStep("clic", .delivered, "la ventana cambió: no abre un menú, el clic ejecutó el botón")
                : DeliveryStep("clic", .noEffect))
        }
        // One more look: a menu that opened after the wait would stay open behind the error.
        if await poll(for: .milliseconds(300), { Self.menu(of: control) != nil }), let late = Self.menu(of: control) {
            await cancel(late, of: control)
        }
        throw MacDriverError.menuDidNotOpen("«\(owner)»", steps)
    }

    /// Opens the control's menu, picks the item named `option` and reads the control back.
    /// Refuses when any menu is already open, its own included: the caller then sees the open
    /// menu's items in the reading and taps one.
    func select(_ option: String, in control: AXUIElement, alias: Int) async throws -> [DeliveryStep] {
        let node = Self.read(control)
        guard !node.role.isEmpty else { throw MacDriverError.staleAlias(alias) }
        let owner = Self.name(of: node)
        let actions = Self.actions(of: control)
        let isPopUp = Self.menuRoles.contains(node.role)
        guard isPopUp || actions.contains("AXShowMenu") else {
            throw MacDriverError.wrongElement("«\(owner)» (\(node.role)) no abre un menú: `select` es para pop-ups y botones con menú. Para lo demás, `tap`.")
        }
        if let open = liveOpenMenu() { throw MacDriverError.menuAlreadyOpen(open.owner) }

        // On a plain button AXPress runs the button, so only its menu action and a click.
        var steps = try await openMenu(of: control, owner: owner, actions: isPopUp ? ["AXPress", "AXShowMenu"] : ["AXShowMenu"])
        guard let menu = Self.menu(of: control) else { throw MacDriverError.menuDidNotOpen("«\(owner)»", steps) }

        let items = Self.items(of: menu)
        guard let item = Self.match(option, in: items) else {
            await cancel(menu, of: control)
            throw MacDriverError.optionNotFound(option: option, options: items.map(\.title))
        }
        let label = "elegir «\(item.title)»"
        let shownBefore = Self.readBack(control)
        let pressed: Bool
        do {
            pressed = try await deliver("AXPress", to: item.element).ran
        } catch {
            await cancel(menu, of: control)
            throw error
        }
        guard pressed else {
            await cancel(menu, of: control)
            throw MacDriverError.axFailed("AXPress en «\(item.title)»", .actionUnsupported)
        }
        // Picking an item closes the menu. One still open means the press did nothing.
        guard await poll({ Self.menu(of: control) == nil }) else {
            await cancel(menu, of: control)
            throw MacDriverError.noEffect("«\(owner)»", steps + [DeliveryStep(label, .noEffect, "el menú siguió abierto; lo cerré")])
        }

        // The control shows the choice in its value (a pop-up) or, for a menu button, maybe in
        // its title or identifier (Calculator: `Mode: scientific; …`). A menu that runs a command
        // shows nothing, so a miss is "delivered", not a failure. Text that was already there
        // before the press (the control's own label, the previous choice) proves nothing.
        // The control may update a moment after the menu closes (Calculator's "Mode"), so wait.
        let wanted = Self.fold(item.title)
        let wasShown = shownBefore.contains { Self.fold($0).contains(wanted) }
        var shown: [String] = []
        var hit: String?
        _ = await poll {
            shown = Self.readBack(control)
            hit = shown.first { Self.fold($0) == wanted }
                ?? (wasShown ? nil : shown.first { Self.fold($0).contains(wanted) })
            return hit != nil
        }
        if let hit {
            steps.append(DeliveryStep(label, .verified, "se lee «\(hit)»"))
        } else {
            steps.append(DeliveryStep(label, .delivered, shown.first.map { "se lee «\($0)»" }))
        }
        return steps
    }

    private func cancel(_ menu: AXUIElement, of control: AXUIElement) async {
        AXUIElementPerformAction(menu, "AXCancel" as CFString)
        _ = await poll { Self.menu(of: control) == nil }
    }

    /// The open menus of the last reading that are still open now.
    private func liveOpenMenu() -> (control: AXUIElement, menu: AXUIElement, owner: String)? {
        openMenus.first { Self.menu(of: $0.control) != nil }
    }

    /// A pop-up's menu is its child only while it is open; when closed there is none. A control
    /// that keeps a menu child while closed (a search field's recents, a custom AppKit control)
    /// would read as always open, so the menu must also have an item on screen.
    static func menu(of control: AXUIElement) -> AXUIElement? {
        let children: [AXUIElement] = attribute(control, "AXChildren") ?? []
        return children.first { (attribute($0, "AXRole") as String?) == "AXMenu" && isShowing($0) }
    }

    /// An open menu measures 0×0, but its items have real frames.
    static func isShowing(_ menu: AXUIElement) -> Bool {
        let items: [AXUIElement] = attribute(menu, "AXChildren") ?? []
        return items.prefix(50).contains { item in
            guard let frame = read(item).frame else { return false }
            return !frame.isEmpty
        }
    }

    private static func items(of menu: AXUIElement) -> [(title: String, element: AXUIElement)] {
        let children: [AXUIElement] = attribute(menu, "AXChildren") ?? []
        return children.compactMap { child in
            let node = read(child)
            guard node.role == "AXMenuItem", node.isEnabled, let title = node.title else { return nil }
            return (title, child)
        }
    }

    /// Exact first, ignoring case, accents and a trailing "…"; else the only item that contains it.
    private static func match(_ option: String, in items: [(title: String, element: AXUIElement)]) -> (title: String, element: AXUIElement)? {
        let wanted = fold(option)
        if let exact = items.first(where: { fold($0.title) == wanted }) { return exact }
        let partial = items.filter { fold($0.title).contains(wanted) }
        return partial.count == 1 ? partial[0] : nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "…")))
    }

    private static func readBack(_ control: AXUIElement) -> [String] {
        let node = read(control)
        return [node.value, node.title, node.identifier, node.description].compactMap { $0 }
    }

    private static func isInToolbar(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = attribute(element, "AXParent")
        for _ in 0..<3 {
            guard let node = current else { return false }
            if (attribute(node, "AXRole") as String?) == "AXToolbar" { return true }
            current = attribute(node, "AXParent")
        }
        return false
    }

    // MARK: - Set value and toggle

    /// Writes `AXValue` in the type the control holds: a date for a date picker, a number for
    /// a slider or stepper, text otherwise. Then reads it back. A password field is written but
    /// neither compared nor echoed.
    func setValue(_ element: AXUIElement, alias: Int, to text: String) async throws -> [DeliveryStep] {
        let node = Self.read(element)
        guard !node.role.isEmpty else { throw MacDriverError.staleAlias(alias) }
        let caption = Self.name(of: node)
        guard Self.isSettable(element, "AXValue") else { throw MacDriverError.notSettable("«\(caption)»") }
        let current: AnyObject? = Self.attribute(element, "AXValue")
        let secure = node.subrole == "AXSecureTextField"

        let value: CFTypeRef
        if let date = current as? Date ?? (node.role == "AXDateTimeArea" ? Date() : nil) {
            guard let parsed = Self.parseDate(text, around: date) else {
                throw MacDriverError.invalidValue("«\(text)» no es una fecha: usá `yyyy-MM-dd HH:mm`, `yyyy-MM-dd` o `HH:mm`, en hora local.")
            }
            value = parsed as CFDate
        } else if current is NSNumber, !Self.textRoles.contains(node.role) {
            guard let number = Self.parseNumber(text) else {
                throw MacDriverError.invalidValue("«\(caption)» guarda un número y «\(text)» no lo es.")
            }
            value = number as CFNumber
        } else {
            value = text as CFString
        }
        if Self.textRoles.contains(node.role) {
            try replaceText(of: element, with: text)
            focusedText = element
        } else {
            try Self.set(element, "AXValue", value)
        }
        // macOS neither reads a password field back nor, in SwiftUI, lets an AX write reach its
        // binding (measured: every write answers success and the bound string stays the same).
        if secure { return [DeliveryStep("AXValue", .delivered, "campo de contraseña: no se puede releer, puede no haber llegado")] }

        // Read back over a short wait: a control may apply the value a moment later.
        var after: AnyObject?
        let same = await poll {
            after = Self.attribute(element, "AXValue")
            return Self.same(value, after)
        }
        let shown = after.flatMap(Self.describe)
        if same { return [DeliveryStep("AXValue", .verified, shown.map { "se lee «\($0)»" })] }
        // A slider or stepper rounds to its step: the write landed, on a nearby value.
        if value is NSNumber, let read = after as? NSNumber, let before = current as? NSNumber,
           read.doubleValue != before.doubleValue {
            return [DeliveryStep("AXValue", .delivered, "se lee «\(read.stringValue)»: el control redondeó")]
        }
        let step = DeliveryStep("AXValue", .noEffect, shown.map { "se lee «\($0)»" })
        throw MacDriverError.noEffect("«\(caption)»", [step])
    }

    /// A number as a person writes it: `0.5`, `0,5`, `1,000.5` or `1.000,5`. With both
    /// separators the last one is the decimal point; a lone `,` is one too.
    private static func parseNumber(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if let comma = text.lastIndex(of: ","), let dot = text.lastIndex(of: ".") {
            let grouping: Character = comma < dot ? "," : "."
            text.removeAll { $0 == grouping }
        }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// Replaces a field's text the way typing does, through the field editor: focus, select
    /// everything, write the selection. Writing `AXValue` instead changes what a SwiftUI
    /// `TextField` shows but not its binding — measured: the field read back the new text while
    /// the view bound to it still showed the old one.
    private func replaceText(of field: AXUIElement, with text: String) throws {
        try Self.set(field, "AXFocused", true as CFBoolean)
        let length = (Self.attribute(field, "AXValue") as String?)?.utf16.count ?? 0
        var all = CFRange(location: 0, length: length)
        if let range = AXValueCreate(.cfRange, &all),
           AXUIElementSetAttributeValue(field, "AXSelectedTextRange" as CFString, range) == .success,
           AXUIElementSetAttributeValue(field, "AXSelectedText" as CFString, text as CFString) == .success {
            return
        }
        try Self.set(field, "AXValue", text as CFString)
    }

    /// Flips a checkbox, radio or switch and checks that it flipped: `AXPress`, then `AXValue`,
    /// then a real click. A checked radio button is refused: clicking it again does nothing.
    func toggle(_ element: AXUIElement, alias: Int) async throws -> [DeliveryStep] {
        let node = Self.read(element)
        guard !node.role.isEmpty else { throw MacDriverError.staleAlias(alias) }
        let caption = Self.name(of: node)
        guard Self.toggleRoles.contains(node.role), let before = Self.checked(element) else {
            throw MacDriverError.wrongElement("«\(caption)» (\(node.role)) no es un checkbox, radio ni switch: no tiene un estado que alternar.")
        }
        if node.role == "AXRadioButton" && before {
            throw MacDriverError.wrongElement("«\(caption)» ya está marcado, y un radio no se desmarca: marcá otro del grupo.")
        }
        let flipped = { Self.checked(element) == !before }
        let detail = before ? "desmarcado" : "marcado"
        var steps: [DeliveryStep] = []

        if Self.actions(of: element).contains("AXPress") {
            if try await deliver("AXPress", to: element).ran {
                if await poll(flipped) { return steps + [DeliveryStep("AXPress", .verified, detail)] }
                steps.append(DeliveryStep("AXPress", .noEffect))
            } else {
                steps.append(DeliveryStep("AXPress", .notDelivered))
            }
        }
        if Self.isSettable(element, "AXValue") {
            let result = AXUIElementSetAttributeValue(element, "AXValue" as CFString, (before ? 0 : 1) as CFNumber)
            if result == .success {
                if await poll(flipped) { return steps + [DeliveryStep("AXValue", .verified, detail)] }
                steps.append(DeliveryStep("AXValue", .noEffect))
            } else if Self.neverRan(result) {
                steps.append(DeliveryStep("AXValue", .notDelivered, "AXError \(result.rawValue)"))
            } else {
                throw MacDriverError.axFailed("AXValue", result)
            }
        }
        if let frame = node.frame, !frame.isEmpty {
            // Unlike `AXValue`, which writes the target state, a click flips: on a control that
            // took the press but reacts late, it would flip it back. Give the press more time.
            if steps.contains(where: { $0.strategy == "AXPress" && $0.outcome == .noEffect }),
               await poll(flipped) {
                return steps + [DeliveryStep("AXPress", .verified, "\(detail), tarde")]
            }
            if try await clickVerified(frame, until: flipped) { return steps + [DeliveryStep("clic", .verified, detail)] }
            steps.append(DeliveryStep("clic", .noEffect))
        }
        throw MacDriverError.noEffect("«\(caption)»", steps)
    }

    private static func checked(_ element: AXUIElement) -> Bool? {
        (attribute(element, "AXValue") as NSNumber?).map { $0.intValue != 0 }
    }

    /// `yyyy-MM-dd HH:mm`, `yyyy-MM-dd` (keeping the time of `reference`) or `HH:mm` (keeping
    /// its day), in local time: the format the reading shows dates in.
    private static func parseDate(_ text: String, around reference: Date) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let day = formatter.date(from: text) {
            let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
        }
        formatter.dateFormat = "HH:mm"
        if let clock = formatter.date(from: text) {
            let time = calendar.dateComponents([.hour, .minute], from: clock)
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: reference)
        }
        return nil
    }

    private static func same(_ written: CFTypeRef, _ read: AnyObject?) -> Bool {
        switch (written, read) {
        case (let a as Date, let b as Date): abs(a.timeIntervalSince(b)) < 60
        case (let a as NSNumber, let b as NSNumber): abs(a.doubleValue - b.doubleValue) < 1e-6
        case (let a as String, let b as String): a == b
        default: false
        }
    }

    private static func describe(_ value: AnyObject) -> String? {
        switch value {
        case let date as Date: format(date)
        case let number as NSNumber: number.stringValue
        case let text as String: text
        default: nil
        }
    }

    // MARK: - Helpers

    /// Performs `action`: whether the app ran it, and the AX error behind a doubtful answer.
    /// Throws when it may have run halfway (a timeout, a generic failure).
    ///
    /// "Unsupported" is not trusted for an action the element advertises: Finder's sidebar cell
    /// answers -25205 (`attributeUnsupported`) to `AXOpen` and navigates anyway, while a Reminders
    /// cell answers the same to `AXPress` and does nothing. The window, compared with how it was
    /// just before the action (`baseline`, or read here), tells them apart.
    private func deliver(_ action: String, to element: AXUIElement, baseline: Int? = nil) async throws -> (ran: Bool, detail: String?) {
        // Read before acting: Finder rebuilds its sidebar on navigating, and the cell is gone after.
        let advertised = Self.actions(of: element).contains(action)
        // Only an advertised action can need the comparison, so only then is the window walked.
        let before = advertised ? baseline ?? fingerprint() : nil
        let result = AXUIElementPerformAction(element, action as CFString)
        if result == .success { return (true, nil) }
        let code = "AXError \(result.rawValue)"
        if result == .actionUnsupported || result == .attributeUnsupported, let before {
            let changed = await poll { fingerprint() != before }
            return changed ? (true, "\(code), pero la ventana cambió") : (false, code)
        }
        if Self.neverRan(result) { return (false, code) }
        throw MacDriverError.axFailed(action, result)
    }

    /// A real click on the middle of `frame`, read back with `condition`.
    private func clickVerified(_ frame: CGRect, until condition: () -> Bool) async throws -> Bool {
        try await click(at: CGPoint(x: frame.midX, y: frame.midY))
        return await poll(for: Self.clickTimeout, condition)
    }

    /// `deliver` for a step with nothing to read back.
    private func deliverStep(_ action: String, to element: AXUIElement, label: String) async throws -> DeliveryStep {
        let answer = try await deliver(action, to: element)
        return DeliveryStep(label, answer.ran ? .delivered : .notDelivered, answer.detail)
    }

    /// Waits for `condition`, checking every 25 ms, up to `timeout`.
    private func poll(for timeout: Duration = effectTimeout, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// What the window shows, summed up the way a reading sees it: the same walk, so a change
    /// the reading would not show does not count, and one it would show does.
    ///
    /// No window (the app quit, the chosen one closed) is a fingerprint of its own, so an
    /// action that closes the window counts as a change. The error itself is not swallowed:
    /// the chosen window is kept, and the reading after the action reports `windowGone`.
    func fingerprint() -> Int {
        guard let app = runningApp() else { return 0 }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        guard let window = try? targetWindow(root: root, app: app, forgetGone: false) else { return 0 }
        let node = Self.read(window)
        let frame = node.frame ?? .zero
        var collector = Collector(windowOrigin: frame.origin)
        collector.walk(window, region: "Ventana", clip: frame)
        return Self.fingerprint(collector.found.map(\.element), title: node.title)
    }

    static func fingerprint(_ elements: [UIElement], title: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(title)
        for element in elements {
            hasher.combine(Collector.key(element))
            hasher.combine(element.isEnabled)
            hasher.combine(element.isChecked)
        }
        return hasher.finalize()
    }

    static func name(of node: Node) -> String {
        node.title ?? node.description ?? node.titledBy ?? node.placeholder ?? node.value ?? node.role
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// `AXSelected` of a row, or `nil` if it has none to read.
    private static func selection(of row: AXUIElement) -> Bool? {
        attribute(row, "AXSelected")
    }

    private static func enclosingRow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = attribute(element, "AXParent")
        for _ in 0..<3 {
            guard let node = current else { return nil }
            if (attribute(node, "AXRole") as String?) == "AXRow" { return node }
            current = attribute(node, "AXParent")
        }
        return nil
    }
}
