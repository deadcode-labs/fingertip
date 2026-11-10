//
//  MacDriver.swift
//  FingertipCore
//
//  Driver para apps de macOS sobre la API de Accesibilidad, sin procesos
//  externos. A diferencia de sim-use, acá sí hay árbol, pero se aplana igual:
//  Jev elige entre una lista y la UI agrupa por región. Todo va por AX y
//  ScreenCaptureKit, así que funciona con la app en segundo plano y sin mover
//  el cursor; el clic real queda como último recurso.
//
//  Los menús no se abren de verdad: AXPress sobre un ítem de la barra no
//  despliega nada, pero sobre un AXMenuItem ejecuta el comando con el menú
//  cerrado y la app detrás. Tocar un menú de la barra lo "despliega" para la
//  próxima lectura, que lista sus ítems; así Jev no elige entre cientos.
//
//  The menus of pop-up and menu buttons are opened for real, and only count as
//  open once the menu shows up as the control's child (see MacActions.swift).
//

import AppKit
import ApplicationServices

nonisolated enum MacDriverError: FingertipError {
    case notTrusted
    case notInstalled(String)
    case notRunning(String)
    case noWindow(String)
    case unknownAlias(Int)
    case noTextField
    case nothingToScroll
    case unsupported(String)
    case axFailed(String, AXError)
    case captureFailed(String)
    case underDebugger(String)
    case notCapturable(String)
    case staleAlias(Int)
    /// Every strategy was delivered and none changed what it should have.
    case noEffect(String, [DeliveryStep])
    /// A menu is already open: opening another would stack them.
    case menuAlreadyOpen(String)
    case menuDidNotOpen(String, [DeliveryStep])
    case optionNotFound(option: String, options: [String])
    case notSettable(String)
    case invalidValue(String)
    /// The action does not apply to this kind of element (toggling a text, selecting in a button).
    case wrongElement(String)
    case ambiguousWindow(app: String, windows: [WindowInfo])
    case unknownWindow(Int)
    case windowGone(String)
    /// The window is open on a Space AX does not reach from here.
    case windowOnOtherSpace(WindowInfo)
    /// The app never ended up under the point, so no click was sent.
    case notClickable(String)
    /// The user kept a mouse button down, so no click was sent: it would cut their drag.
    case mouseButtonHeld
    /// `bring_to_front` asked for the window and it did not end up in front within 2 s.
    case notBroughtForward(String)
    /// The app didn't answer Accessibility within the messaging timeout: its main thread is busy.
    case notResponding(String)

    var code: String {
        switch self {
        case .notTrusted: "accessibility_not_granted"
        case .notInstalled: "app_not_installed"
        case .notRunning: "app_not_running"
        case .noWindow: "no_window"
        case .unknownAlias: "unknown_alias"
        case .noTextField: "no_text_field"
        case .nothingToScroll: "nothing_to_scroll"
        case .unsupported: "unsupported"
        case .axFailed: "ax_failed"
        case .captureFailed: "capture_failed"
        case .underDebugger: "under_debugger"
        case .notCapturable: "not_capturable"
        case .staleAlias: "stale_alias"
        case .noEffect: "no_effect"
        case .menuAlreadyOpen: "menu_already_open"
        case .menuDidNotOpen: "menu_did_not_open"
        case .optionNotFound: "option_not_found"
        case .notSettable: "not_settable"
        case .invalidValue: "invalid_value"
        case .wrongElement: "wrong_element"
        case .ambiguousWindow: "ambiguous_window"
        case .unknownWindow: "unknown_window"
        case .windowGone: "window_gone"
        case .windowOnOtherSpace: "window_on_other_space"
        case .notClickable: "not_clickable"
        case .mouseButtonHeld: "mouse_button_held"
        case .notBroughtForward: "not_brought_forward"
        case .notResponding: "app_not_responding"
        }
    }

    /// Safe when nothing reached the app. An AX call that failed is safe only if its error says
    /// it never ran; a timeout or a generic failure may have half-happened. A press with no
    /// visible effect is not safe either: the effect may just be late.
    var retrySafe: Bool {
        switch self {
        case .unknownAlias, .staleAlias, .noWindow, .captureFailed, .notResponding: true
        case .menuAlreadyOpen, .optionNotFound, .notSettable, .invalidValue, .wrongElement,
             .ambiguousWindow, .unknownWindow, .windowGone, .windowOnOtherSpace, .notClickable, .mouseButtonHeld: true
        // A menu that opened late was cancelled (`openMenu`). What is not safe is a step that
        // changed the window: a click on a plain button, which ran it.
        case .menuDidNotOpen(_, let steps): !steps.contains { $0.outcome == .delivered }
        case .axFailed(_, let error): MacDriver.neverRan(error)
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            "The Accessibility permission is missing. Grant it to the running process (the app, or the terminal running Claude Code) in System Settings → Privacy & Security → Accessibility and connect again."
        case .notInstalled(let bundleID):
            "No installed app has bundle id \(bundleID)."
        case .notRunning(let bundleID):
            "\(bundleID) is not running."
        case .noWindow(let bundleID):
            "\(bundleID) has no open window."
        case .unknownAlias(let alias):
            "There is no element @\(alias) in the last reading: read the screen again."
        case .staleAlias(let alias):
            "@\(alias) no longer exists: the screen changed since the last reading. Read it again."
        case .noTextField:
            "There is no focused text field to type into."
        case .nothingToScroll:
            "There is nothing scrollable in the window."
        case .unsupported(let what):
            "There is no \(what) on macOS."
        case .axFailed(let what, let error):
            "Accessibility refused \(what) (AXError \(error.rawValue))."
        case .captureFailed(let detail):
            "Couldn't capture the window: \(detail)"
        case .notCapturable(let name):
            "\(name)'s window is not on this desktop (another Space, full screen or minimized): it can't be captured. Reading and acting still work; to see the mirror, bring it to this desktop."
        case .underDebugger(let name):
            "\(name) is running under the Xcode debugger: if it is killed, Xcode intercepts the signal and leaves it paused instead of quitting. Leave the bundle id empty so it isn't relaunched, or run the app without the debugger."
        case .noEffect(let what, let steps):
            "\(what): the app took the action but nothing changed. Tried: \(steps.map(\.caption).joined(separator: " → "))."
        case .menuAlreadyOpen(let owner):
            "A menu is already open (\(owner)): choose one of its items, or tap its control again to close it, before opening another."
        case .menuDidNotOpen(let owner, let steps):
            "The menu of \(owner) didn't open. Tried: \(steps.map(\.caption).joined(separator: " → "))."
        case .optionNotFound(let option, let options):
            "There is no «\(option)» in the menu; closed it without choosing. Options: \(options.map { "«\($0)»" }.joined(separator: ", "))."
        case .notSettable(let what):
            "The value of \(what) can't be changed: it is read-only."
        case .invalidValue(let detail):
            detail
        case .wrongElement(let detail):
            detail
        case .ambiguousWindow(let app, let windows):
            "\(app) has \(windows.count) windows: \(windows.map { $0.caption + ($0.isOnOtherSpace ? " (on another desktop)" : "") }.joined(separator: ", ")). Choose one with `read_screen` and `window` (`list_windows` shows them with their position)."
        case .unknownWindow(let number):
            "The app has no window #\(number): see `list_windows`."
        case .mouseButtonHeld:
            "Didn't do the real click: a mouse button is held down (the user is dragging or clicking) and wasn't released within 2 s. A click now would break the drag. Nothing was touched; try again in a moment."
        case .notClickable(let name):
            "Didn't do the real click: \(name)'s window wasn't in front at that point within 2 s (another window covers it, or it is on another Space). Nothing was touched; bring it to the front and try again."
        case .windowOnOtherSpace(let window):
            "Window \(window.caption) is on another desktop and Accessibility can't reach it from here. Bring it over with `bring_to_front` (if allowed in Fingertip → Settings → General), or switch to that desktop and read again."
        case .notBroughtForward(let window):
            "Asked to bring window \(window) to the front and it wasn't in front within 2 s (the app doesn't list it in its Window menu, or has another with the same title). Switch to its desktop by hand and read again."
        case .notResponding(let name):
            "\(name) didn't answer Accessibility within 2 s: its main thread is busy or hung, so its windows can't be read or brought forward. Nothing was touched. Read again in a moment; if it keeps failing, the app itself is stuck (`sample` its process to see where)."
        case .windowGone(let detail):
            "The chosen window is gone (\(detail)). Choose another with `list_windows`."
        }
    }
}

/// Una app de macOS que se puede elegir como dispositivo. Se identifica por
/// la ruta del bundle y no por el bundle id: la build de Xcode y la copia de
/// /Applications comparten bundle id, y pueden estar corriendo las dos.
public nonisolated struct MacApp: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let bundleURL: URL

    public var id: URL { bundleURL }

    public init(bundleID: String, name: String, bundleURL: URL) {
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
    }

    /// Las apps con ícono en el Dock, menos esta misma. Device Hub aparece con
    /// pid -1 sin ser un proceso: se descarta.
    @MainActor
    public static func running() -> [MacApp] {
        var seen = Set<URL>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 && $0.processIdentifier != getpid() }
            .compactMap { app -> MacApp? in
                guard let bundleID = app.bundleIdentifier, let url = app.bundleURL?.standardizedFileURL else { return nil }
                return MacApp(bundleID: bundleID, name: app.localizedName ?? bundleID, bundleURL: url)
            }
            .filter { seen.insert($0.bundleURL).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

actor MacDriver: ScreenDriver {
    nonisolated let bundleID: String
    /// La copia concreta elegida: entre dos instancias con el mismo bundle id,
    /// se lee, se mata y se relanza esta.
    nonisolated let bundleURL: URL
    nonisolated var name: String { "Accessibility" }

    /// Contenedores y chrome: se recorren pero no se ofrecen como candidatos.
    /// Se descartan acá y no en `UIElement.isActionable` porque `Cell` en iOS
    /// es justamente lo que se toca, y en macOS es la caja de una fila.
    private static let containerRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXGroup", "AXSplitGroup", "AXSplitter",
        "AXScrollArea", "AXScrollBar", "AXToolbar", "AXMenuBar", "AXMenu", "AXOutline",
        "AXTable", "AXList", "AXRow", "AXColumn", "AXCell", "AXLayoutArea", "AXTabGroup",
        "AXWebArea", "AXUnknown", "AXBrowser", "AXGrid", "AXRadioGroup"
    ]
    /// En estos el texto visible está en `AXValue`; en el resto, `AXValue` es
    /// estado (un checkbox da 0/1, un badge "1") y no sirve de rótulo.
    static let textRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXComboBox"
    ]
    /// En estos `AXValue` es 0/1: marcado o no.
    static let toggleRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXSwitch"
    ]
    /// Controls whose tap opens a menu.
    static let menuRoles: Set<String> = ["AXPopUpButton", "AXMenuButton"]
    /// Una lectura por nodo en vez de una por atributo: con atributos sueltos,
    /// System Settings (212 nodos) tardaba 1.7 s.
    private static let attributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue",
        "AXIdentifier", "AXPosition", "AXSize", "AXEnabled", "AXChildren",
        "AXPlaceholderValue", "AXTitleUIElement"
    ]
    /// Tope de nodos recorridos: una web o una tabla enorme no deben colgar el paso.
    private static let maxNodes = 3000

    /// Alias → elemento de la última lectura. Es el equivalente de la caché `@N`
    /// de sim-use, con la misma regla: actuar sin releer apunta a la pantalla vieja.
    var elements: [Int: AXUIElement] = [:]
    /// Áreas desplazables de la última lectura, con su frame relativo a la ventana.
    private var scrollAreas: [(element: AXUIElement, frame: CGRect)] = []
    /// Frame de la ventana en coordenadas globales: los `bounds` son relativos a ella.
    var windowFrame: CGRect = .zero
    /// Último campo de texto tocado: ahí van `inputText` y `eraseText`.
    var focusedText: AXUIElement?
    /// Si la app ya se vio corriendo, que no esté es una muerte, no un error de uso.
    private var wasRunning = false
    /// Menú de la barra que la próxima lectura lista desplegado. Cualquier otra
    /// acción lo cierra, como haría un menú real.
    var expandedMenu: String?
    /// Pop-up menus open at the last reading, with the control that owns each and its name.
    var openMenus: [(control: AXUIElement, menu: AXUIElement, owner: String)] = []
    /// The window reads and actions go to: its number, and the process start time, so a
    /// relaunched app that reuses the number is not mistaken for the same window.
    var chosenWindow: (number: CGWindowID, processStart: Double)?
    private let recorder = ProcessRecorder()
    /// The window being recorded: while it is, its screenshots come from the recorder.
    private var recordedWindow: CapturedWindow?

    init(app: MacApp) {
        bundleID = app.bundleID
        bundleURL = app.bundleURL
    }

    // MARK: - Disponibilidad

    /// Si falta el permiso, macOS muestra su diálogo para darlo. Grabación de
    /// pantalla no bloquea: sin ella solo falla el mirror.
    func preflight() async throws {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw MacDriverError.notTrusted }
    }

    @discardableResult
    func disconnect() async -> URL? {
        var recording: URL?
        recordedWindow = nil
        do {
            recording = try await recorder.stop()
        } catch RecordingError.notRecording {
        } catch {
            FileHandle.standardError.write(Data("recording: couldn't close the recording on disconnect: \(error.localizedDescription)\n".utf8))
        }
        elements = [:]
        scrollAreas = []
        focusedText = nil
        openMenus = []
        chosenWindow = nil
        return recording
    }

    // MARK: - Lectura de pantalla

    func describeUI() async throws -> ScreenHierarchy {
        guard let app = runningApp() else {
            guard wasRunning else { throw MacDriverError.notRunning(bundleID) }
            return ScreenHierarchy(elements: [], screenSize: .zero, appLabel: nil, appPackage: nil, vanishedApps: [bundleID])
        }
        wasRunning = true

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let window = try targetWindow(root: root, app: app)
        windowFrame = Self.read(window).frame ?? .zero

        var collector = Collector(windowOrigin: windowFrame.origin)
        collector.walk(window, region: "Ventana", clip: windowFrame)
        if let menuBar: AXUIElement = Self.attribute(root, "AXMenuBar") {
            collector.walkMenuBar(menuBar, expanded: expandedMenu)
        }

        elements = Dictionary(uniqueKeysWithValues: collector.found.enumerated().map { ($0.offset + 1, $0.element.ax) })
        scrollAreas = collector.scrollAreas
        openMenus = collector.openMenus
        let uiElements = collector.found.enumerated().map { index, entry in
            var element = entry.element
            element.alias = index + 1
            return element
        }

        return ScreenHierarchy(
            elements: uiElements,
            screenSize: windowFrame.size,
            appLabel: app.localizedName,
            appPackage: bundleID,
            vanishedApps: [],
            screenOrigin: windowFrame.origin
        )
    }

    /// La ventana con foco; si la app no está activa puede no haberla, y
    /// entonces la principal o la primera.
    static func window(of root: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = attribute(root, "AXFocusedWindow") { return focused }
        if let main: AXUIElement = attribute(root, "AXMainWindow") { return main }
        let windows: [AXUIElement]? = attribute(root, "AXWindows")
        return windows?.first
    }

    /// Recorre el árbol y se queda con lo que tiene identidad y está a la vista.
    struct Collector {
        let windowOrigin: CGPoint
        var found: [(ax: AXUIElement, element: UIElement)] = []
        var scrollAreas: [(element: AXUIElement, frame: CGRect)] = []
        var openMenus: [(control: AXUIElement, menu: AXUIElement, owner: String)] = []
        var visited = 0
        /// SwiftUI suele exponer un texto dos veces —el contenedor y el texto de
        /// adentro— con el mismo rótulo y el mismo frame. Tocar cualquiera da lo
        /// mismo; el segundo solo duplica la lectura y el Choice de Jev.
        var seen: Set<String> = []
        /// Region names already given to scroll areas, so two areas never share one.
        var areaNames: Set<String> = []

        static func key(_ element: UIElement) -> String {
            [element.type, element.label ?? "", element.text ?? "", element.identifier ?? "", "\(element.bounds)"]
                .joined(separator: "\u{1F}")
        }

        /// `parent` and `owner` are the node above and its name: a pop-up's menu is the
        /// child of its control and is listed under the control's name.
        mutating func walk(_ ax: AXUIElement, region: String, clip: CGRect, parent: AXUIElement? = nil, owner: String? = nil) {
            guard visited < MacDriver.maxNodes else { return }
            visited += 1
            let node = MacDriver.read(ax)
            var clip = clip

            // An open pop-up menu measures 0×0 at the bottom of the screen, while its items
            // have real frames, often outside the window: it is listed whole, before the
            // frame check that would prune it. A closed pop-up has no menu child at all; a
            // control that keeps one while closed has no item on screen in it, and is skipped.
            if node.role == "AXMenu", let parent {
                guard MacDriver.isShowing(ax) else { return }
                let name = owner ?? "menú"
                openMenus.append((parent, ax, name))
                walkMenu(ax, path: name)
                return
            }

            if let frame = node.frame {
                // Tamaño cero: un menú cerrado, una fila colapsada. Fuera del
                // clip: scrolleado fuera de la vista. Nada de abajo se ve.
                if frame.isEmpty || !frame.intersects(clip) { return }
                if node.role == "AXScrollArea" {
                    clip = clip.intersection(frame)
                    scrollAreas.append((ax, frame.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y)))
                }
            }

            let region = switch node.role {
            case "AXToolbar": "Toolbar"
            case "AXSheet": "Hoja"
            case "AXScrollArea": areaName(node, inside: region)
            default: region
            }

            if let element = node.element(region: region, windowOrigin: windowOrigin),
               seen.insert(Self.key(element)).inserted {
                found.append((ax, element))
            }
            let name = node.title ?? node.description ?? node.titledBy ?? node.value
            for child in node.children {
                walk(child, region: region, clip: clip, parent: ax, owner: name)
            }
        }

        /// Each scroll area (a sidebar, a message list, the content) is a region of its own,
        /// so a dense window can be read one part at a time. The area rarely names itself;
        /// the list or table inside it often does.
        mutating func areaName(_ node: Node, inside parent: String) -> String {
            let inner = node.children.first.map(MacDriver.read)
            let named = [node.description, node.title, node.identifier, inner?.description, inner?.title, inner?.identifier]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                // `_NS:61` is an identifier AppKit makes up for nib views: it names nothing.
                .first { !$0.isEmpty && !$0.hasPrefix("_NS:") }
            let prefix = parent == "Ventana" ? "" : "\(parent) › "
            var name = prefix + (named ?? "Área \(areaNames.count + 1)")
            if areaNames.contains(name) { name += " \(areaNames.count + 1)" }
            areaNames.insert(name)
            return name
        }

        /// Los menús de la barra, sin el de Apple, y los ítems del desplegado.
        /// Sin frames: con la app detrás todo mide 0×0, y no importa, porque
        /// se actúa por AXPress y nunca por coordenadas.
        mutating func walkMenuBar(_ menuBar: AXUIElement, expanded: String?) {
            for item in MacDriver.read(menuBar).children.dropFirst() {
                let node = MacDriver.read(item)
                guard let title = node.title else { continue }
                found.append((item, Self.menuElement(label: title, type: "MenuBarItem", node: node)))
                if title == expanded, let menu = node.children.first {
                    walkMenu(menu, path: title)
                }
            }
        }

        /// Los submenús se aplanan con la ruta en el rótulo ("Edit › Find › Find…"):
        /// los separadores no tienen título y los ítems deshabilitados no se ofrecen.
        mutating func walkMenu(_ menu: AXUIElement, path: String) {
            for item in MacDriver.read(menu).children {
                guard visited < MacDriver.maxNodes else { return }
                visited += 1
                let node = MacDriver.read(item)
                guard let title = node.title, node.isEnabled else { continue }
                if let submenu = node.children.first {
                    walkMenu(submenu, path: "\(path) › \(title)")
                } else {
                    found.append((item, Self.menuElement(label: "\(path) › \(title)", type: "MenuItem", node: node)))
                }
            }
        }

        private static func menuElement(label: String, type: String, node: Node) -> UIElement {
            UIElement(alias: nil, identifier: nil, text: nil, label: label, type: type,
                      region: "Menú", bounds: .zero, isEnabled: node.isEnabled)
        }
    }

    struct Node {
        var role = ""
        var subrole: String?
        var title: String?
        var description: String?
        var value: String?
        var identifier: String?
        var frame: CGRect?
        var isEnabled = true
        var children: [AXUIElement] = []
        /// Un buscador suele no tener otra cosa que lo nombre.
        var placeholder: String?
        /// El texto que lo rotula desde afuera (`AXTitleUIElement`). Así se
        /// nombran los controles de un `Form` de SwiftUI: un `Picker("Agente")`
        /// o un `DatePicker("Hora")` no tienen título propio.
        var titledBy: String?
        /// `AXValue` de un checkbox, radio o switch.
        var isChecked: Bool?
        /// `AXValue` de un `AXDateTimeArea`.
        var date: Date?

        /// `nil` si es un contenedor o si no hay forma de nombrarlo.
        func element(region: String, windowOrigin: CGPoint) -> UIElement? {
            guard !MacDriver.containerRoles.contains(role), let frame else { return nil }
            // En un pop-up el valor es la opción elegida; en una fecha, la fecha.
            // A password field's value never leaves the driver, whatever the app exposes.
            let shown = subrole == "AXSecureTextField"
                ? nil
                : MacDriver.textRoles.contains(role) || role == "AXPopUpButton"
                ? value
                : date.map(MacDriver.format)
            let element = UIElement(
                alias: nil,
                identifier: identifier,
                text: shown,
                label: title ?? description ?? titledBy ?? placeholder,
                type: MacDriver.type(role: role, subrole: subrole),
                region: region,
                bounds: frame.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y),
                isEnabled: isEnabled,
                isChecked: isChecked
            )
            return element.hasIdentity ? element : nil
        }
    }

    /// El mismo formato que usan las apps para fechas de máquina, en hora local.
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// El rol sin el prefijo `AX`, salvo los campos de texto, que se nombran
    /// como en iOS para que `UIElement.acceptsText` los reconozca.
    private static func type(role: String, subrole: String?) -> String {
        switch (role, subrole) {
        case ("AXTextField", "AXSecureTextField"): "SecureTextField"
        case ("AXTextField", "AXSearchField"): "SearchField"
        case ("AXTextArea", _): "TextView"
        default: role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
    }

    static func read(_ ax: AXUIElement) -> Node {
        var values: CFArray?
        let names = attributes as CFArray
        guard AXUIElementCopyMultipleAttributeValues(ax, names, [], &values) == .success,
              let values = values as? [AnyObject], values.count == attributes.count
        else { return Node() }

        /// Un atributo que falta vuelve como un AXValue de error, no como nil.
        func string(_ index: Int) -> String? {
            guard let text = values[index] as? String, !text.isEmpty else { return nil }
            return text
        }

        var node = Node()
        node.role = string(0) ?? ""
        node.subrole = string(1)
        node.title = string(2)
        node.description = string(3)
        // A password field's value is dropped here, at the source, so it can never become a
        // name in an error, a menu owner or a match, whatever the app exposes.
        node.value = node.subrole == "AXSecureTextField" ? nil : string(4)
        node.identifier = string(5)
        if let origin = point(values[6]), let size = size(values[7]) {
            node.frame = CGRect(origin: origin, size: size)
        }
        node.isEnabled = (values[8] as? Bool) ?? true
        node.children = (values[9] as? [AXUIElement]) ?? []
        node.placeholder = string(10)
        if toggleRoles.contains(node.role) {
            node.isChecked = (values[4] as? NSNumber).map { $0.intValue != 0 }
        }
        node.date = values[4] as? Date
        // Una llamada más, solo para lo que no tiene nombre propio.
        if node.title == nil, node.description == nil,
           CFGetTypeID(values[11]) == AXUIElementGetTypeID() {
            let titleElement = values[11] as! AXUIElement
            node.titledBy = attribute(titleElement, "AXValue") ?? attribute(titleElement, "AXTitle")
        }
        return node
    }

    // MARK: - Acciones

    @discardableResult
    func perform(_ action: DeviceAction) async throws -> [DeliveryStep] {
        let expanded = expandedMenu
        expandedMenu = nil
        func element(_ alias: Int) throws -> AXUIElement {
            guard let element = elements[alias] else { throw MacDriverError.unknownAlias(alias) }
            return element
        }
        switch action {
        case .tap(let alias, let point):
            if let alias {
                return try await tap(element(alias), alias: alias, expanded: expanded)
            }
            // The window now, not at the last reading: a closed or ambiguous one is an error.
            let origin = try liveWindowOrigin() ?? windowFrame.origin
            try await click(at: CGPoint(x: origin.x + point.x, y: origin.y + point.y))
            return [DeliveryStep("click", .delivered)]
        case .setValue(let alias, let value):
            return try await setValue(element(alias), alias: alias, to: value)
        case .toggle(let alias):
            return try await toggle(element(alias), alias: alias)
        case .select(let alias, let option):
            return try await select(option, in: element(alias), alias: alias)
        case .inputText(let text):
            try insert(text)
        case .eraseText(let characters):
            try erase(characters)
        case .swipe(let from, let to):
            try scroll(at: from, down: to.y < from.y)
        case .pressButton(let button):
            throw MacDriverError.unsupported("a \"\(button)\" button")
        case .submit:
            try submit()
        }
        return []
    }

    /// Un Return de teclado dirigido al proceso: llega al campo con foco aunque
    /// la app esté detrás. No sirve `AXConfirm`, que los campos de SwiftUI
    /// anuncian: dispara el `onSubmit` del campo pero no el botón
    /// `.defaultAction` del formulario, que es lo que hace Return cuando el
    /// campo no tiene `onSubmit`.
    private func submit() throws {
        let field = try textTarget()
        try Self.set(field, "AXFocused", true as CFBoolean)
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: isDown)
            // An event from `.hidSystemState` carries the modifiers the user is holding (measured
            // with ⌘): this Return would go out as ⌘Return. Same in `postKeys` and `click`.
            event?.flags = []
            event?.postToPid(app.processIdentifier)
        }
    }

    /// Brings the app forward and waits until a click at `point` would land on it: the topmost
    /// window there is the app's and AX lists its windows again. Being frontmost is not enough.
    /// Measured from a full-screen terminal, with Calculator on the desktop Space: frontmost at
    /// 133 ms, its window on screen at 245 ms, listed by AX at 546 ms. A click sent at 280 ms
    /// fell into the Space animation and opened nothing. If it never gets there, no click is
    /// sent: a blind click would land on whatever covers the app, such as the user's terminal.
    ///
    /// The app being in front is not enough either when it has several windows: the target
    /// window is raised (`AXRaise`), and the window under the point must not be another of the
    /// app's windows. A window of the app that AX does not list as one (a sheet) is accepted.
    ///
    /// It also waits while the user holds a mouse button: a down/up posted in the middle of
    /// their drag would end it and leave their own release without a press.
    private func bringForward(clickingAt point: CGPoint) async throws {
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 2)
        // Asked of the app: the system-wide `AXFocusedApplication` fails with
        // kAXErrorCannotComplete (-25204) from a command-line process such as the MCP.
        if Self.attribute(root, "AXFrontmost") != true { app.activate() }
        let deadline = ContinuousClock.now + .seconds(2)
        var raised = false
        while true {
            // A window on another Space is not listed until the switch ends; until then the
            // target cannot be told from a closed one.
            let windows: [AXUIElement] = Self.attribute(root, "AXWindows") ?? []
            if !windows.isEmpty, let target = try? targetWindow(root: root, app: app, forgetGone: false) {
                if !raised {
                    AXUIElementPerformAction(target, kAXRaiseAction as CFString)
                    raised = true
                }
                let number = Self.windowNumber(target)
                let others = Set(windows.compactMap(Self.windowNumber)).subtracting([number].compactMap { $0 })
                if let top = Self.topWindow(at: point), top.pid == pid, !others.contains(top.number),
                   !Self.isMouseButtonHeld() { break }
            }
            guard ContinuousClock.now < deadline else {
                // The window errors (closed, ambiguous) say more than "not clickable".
                if !windows.isEmpty { _ = try targetWindow(root: root, app: app) }
                if Self.isMouseButtonHeld() { throw MacDriverError.mouseButtonHeld }
                throw MacDriverError.notClickable(app.localizedName ?? bundleID)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The window can report in while its animation is still ending.
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Any button of the user's mouse or trackpad is down right now.
    private static func isMouseButtonHeld() -> Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.hidSystemState, button: $0) }
    }

    /// The topmost normal window at `point`, in the window server's front-to-back order: its
    /// owner and number. Higher layers (menus, the Fingertip pointer, the menu bar) are skipped.
    private static func topWindow(at point: CGPoint) -> (pid: pid_t, number: CGWindowID)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(point)
            else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let number = window[kCGWindowNumber as String] as? CGWindowID
            else { return nil }
            return (pid, number)
        }
        return nil
    }

    /// El único camino que mueve el cursor: hace falta traer la app al frente
    /// para que el clic le llegue a ella y no a lo que esté encima.
    func click(at point: CGPoint) async throws {
        try await bringForward(clickingAt: point)
        // A press may have started during the last 100 ms of `bringForward`.
        guard !Self.isMouseButtonHeld() else { throw MacDriverError.mouseButtonHeld }
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = [] // Not a ⌘-click when the user holds ⌘ (see `submit`).
            event?.post(tap: .cghidEventTap)
        }
    }

    /// `AXSelectedText` inserta en el cursor como si se tipeara, y acepta
    /// cualquier Unicode: acá no existe el límite del teclado US del simulador.
    private func insert(_ text: String) throws {
        let field = try textTarget()
        if (Self.attribute(field, "AXSubrole") as String?) == "AXSecureTextField" {
            try typeKeys(text, into: field)
            return
        }
        if AXUIElementSetAttributeValue(field, "AXSelectedText" as CFString, text as CFString) == .success { return }
        let current: String = Self.attribute(field, "AXValue") ?? ""
        try Self.set(field, "AXValue", (current + text) as CFString)
    }

    /// A password field takes no AX write: `AXSelectedText` and `AXValue` answer success and
    /// the field stays empty. Keyboard events posted to the process do reach it, one per
    /// character carrying its Unicode string, like `submit`'s Return.
    private func typeKeys(_ text: String, into field: AXUIElement) throws {
        try postKeys(text.map { (0, Array(String($0).utf16)) }, to: field)
    }

    /// Each key is a virtual key code and, for text, the UTF-16 it types.
    private func postKeys(_ keys: [(code: CGKeyCode, text: [UniChar]?)], to field: AXUIElement) throws {
        try Self.set(field, "AXFocused", true as CFBoolean)
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let source = CGEventSource(stateID: .hidSystemState)
        for key in keys {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: isDown)
                event?.flags = [] // A held ⌘ would turn a typed letter into a shortcut (see `submit`).
                if let text = key.text {
                    event?.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
                }
                event?.postToPid(app.processIdentifier)
            }
        }
    }

    private func erase(_ characters: Int) throws {
        let field = try textTarget()
        if (Self.attribute(field, "AXSubrole") as String?) == "AXSecureTextField" {
            try postKeys(Array(repeating: (0x33, nil), count: characters), to: field) // 0x33 = Delete
            return
        }
        let current: String = Self.attribute(field, "AXValue") ?? ""
        try Self.set(field, "AXValue", String(current.dropLast(characters)) as CFString)
    }

    private func textTarget() throws -> AXUIElement {
        if let focusedText { return focusedText }
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = Self.attribute(root, "AXFocusedUIElement") else { throw MacDriverError.noTextField }
        return focused
    }

    /// Mueve la barra vertical del área bajo el punto (la más grande si hay
    /// anidadas; si ninguna lo contiene, la más grande de la ventana). Las
    /// acciones `AXScroll…ByPage` que anuncian las áreas de SwiftUI fallan, y una
    /// rueda enviada al proceso no llega con la app detrás; la barra sí responde.
    private func scroll(at point: CGPoint, down: Bool) throws {
        // Sin barra vertical, el contenido entra entero: no hay nada que mover.
        let scrollable = scrollAreas
            .compactMap { area -> (bar: AXUIElement, area: AXUIElement, frame: CGRect)? in
                guard let bar: AXUIElement = Self.attribute(area.element, "AXVerticalScrollBar") else { return nil }
                return (bar, area.element, area.frame)
            }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        guard let target = scrollable.first(where: { $0.frame.contains(point) }) ?? scrollable.first else {
            throw MacDriverError.nothingToScroll
        }

        // La barra va de 0 a 1 sobre lo que sobra del contenido: una página
        // (el 80% de lo visible, para que algo quede de referencia) es esa
        // fracción de lo que sobra.
        let visible = target.frame.height
        let overflow = max(Self.contentHeight(of: target.area) - visible, 1)
        let step = min(1, visible * 0.8 / overflow)
        let current = (Self.attribute(target.bar, "AXValue") as NSNumber?)?.doubleValue ?? 0
        let next = min(1, max(0, current + (down ? step : -step)))
        try Self.set(target.bar, "AXValue", next as CFNumber)
    }

    /// Alto del contenido de un área desplazable: las filas fuera de la vista
    /// siguen en el árbol con su posición real, así que la unión de los frames
    /// del contenido y sus hijos da el total.
    private static func contentHeight(of area: AXUIElement) -> CGFloat {
        let contents: [AXUIElement] = attribute(area, "AXContents") ?? attribute(area, "AXChildren") ?? []
        var union = CGRect.null
        for element in contents {
            let node = read(element)
            for frame in [node.frame] + node.children.map({ read($0).frame }) {
                if let frame, !frame.isEmpty { union = union.union(frame) }
            }
        }
        return union.isNull ? 0 : union.height
    }

    // MARK: - Ciclo de vida

    /// Arranca activada y, en cuanto tiene ventana, le devuelve el foco a la
    /// app que estaba al frente. Lanzada con `activates = false`, la ventana
    /// existe para AX pero el window server nunca la muestra y ScreenCaptureKit
    /// no la ve; basta con que haya estado al frente una vez. `ApplePersistence-
    /// IgnoreState` evita que restaure las ventanas de la sesión anterior, que
    /// es lo que hace que cada corrida arranque igual.
    func launch(bundleID: String) async throws {
        // `terminate` no toca una app depurada; si sigue viva, es esa.
        if let traced = instances(of: bundleID).first(where: { Self.isBeingDebugged($0.processIdentifier) }) {
            throw MacDriverError.underDebugger(traced.localizedName ?? bundleID)
        }
        guard let url = bundleID == self.bundleID
            ? bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            throw MacDriverError.notInstalled(bundleID)
        }
        // A fresh process has fresh windows: the chosen one is gone.
        if bundleID == self.bundleID { chosenWindow = nil }
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, Self.window(of: root) == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))
        if let previous, previous.processIdentifier != app.processIdentifier {
            previous.activate()
        }
    }

    /// Forzado, como `simctl terminate`: un "¿Guardar cambios?" no puede
    /// trabar el arranque de una corrida. Espera a que el proceso desaparezca.
    /// A una app bajo el depurador no la toca: Xcode intercepta la señal y la
    /// deja pausada, y todas las lecturas AX siguientes se cuelgan hasta el
    /// timeout. `launch` es quien lo reporta, porque este error el agente lo
    /// trata como "no estaba corriendo".
    func terminate(bundleID: String) async throws {
        let apps = instances(of: bundleID)
        guard !apps.isEmpty else { throw MacDriverError.notRunning(bundleID) }
        if let traced = apps.first(where: { Self.isBeingDebugged($0.processIdentifier) }) {
            throw MacDriverError.underDebugger(traced.localizedName ?? bundleID)
        }
        let pids = apps.map(\.processIdentifier)
        if bundleID == self.bundleID { chosenWindow = nil }
        apps.forEach { $0.forceTerminate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Las instancias de esa app. Si es la elegida, solo las de su copia: matar
    /// la build de Xcode no tiene que cerrar también la de /Applications.
    private func instances(of bundleID: String) -> [NSRunningApplication] {
        var apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        // Empty for a moment after another process captured the screen, which the capture
        // child (see `WindowCapture`) does on every screenshot. The workspace's list is not.
        if apps.isEmpty {
            apps = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
            }
        }
        return apps.filter {
            !$0.isTerminated && (bundleID != self.bundleID || $0.bundleURL?.standardizedFileURL == bundleURL)
        }
    }

    /// `P_TRACED`: hay un depurador enganchado al proceso.
    private static func isBeingDebugged(_ pid: pid_t) -> Bool {
        processInfo(pid).map { $0.kp_proc.p_flag & P_TRACED != 0 } ?? false
    }

    /// When the process started, in seconds since 1970: with the window number, it tells a
    /// window apart from one a relaunched app happens to give the same number.
    static func processStart(_ pid: pid_t) -> Double? {
        processInfo(pid).map { Double($0.kp_proc.p_starttime.tv_sec) + Double($0.kp_proc.p_starttime.tv_usec) / 1e6 }
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    // MARK: - Captura

    /// La ventana se busca por su frame: en System Settings es de la extensión
    /// del panel (`com.apple.systempreferences.GeneralSettings`), no de la app.
    /// Una ventana de otro Space le llega a ScreenCaptureKit con un frame sin
    /// sentido (Calculator: 55×96 fuera de la pantalla), así que no coincide y
    /// no se captura; AX la sigue leyendo bien.
    ///
    /// While the same window is being recorded, the recorder answers: a `capture` child would cut
    /// the video when it exits (see `WindowCapture.record`).
    func screenshot() async throws -> Data {
        let (target, window, name) = try captureTarget()
        if let recordedWindow {
            guard recordedWindow.matches(window) else {
                throw MacDriverError.captureFailed("another window is being recorded, and capturing this one would cut that video. Stop the recording first.")
            }
            if let png = try await recorder.frame(crop: target.crop) { return png }
            // The recorder is gone (the window closed): nothing left to cut.
        }
        let result: SubprocessOutput
        do {
            result = try await Subprocess.run(
                WindowCapture.helper, ["capture", try Self.json(target)],
                label: "fingertip-mcp capture", timeout: .seconds(15), isRead: true
            )
        } catch is SubprocessTimeout {
            throw MacDriverError.captureFailed("ScreenCaptureKit didn't answer within 15 s")
        }
        switch result.status {
        case 0: return result.stdout
        case WindowCapture.notCapturableStatus: throw MacDriverError.notCapturable(name)
        default: throw MacDriverError.captureFailed(String(decoding: result.stderr, as: UTF8.self))
        }
    }

    /// What the capture child needs to find the app's front window in ScreenCaptureKit, the window
    /// that gets captured (a sheet's parent), and the app's name for errors. Shared by
    /// `screenshot` and `startRecording`.
    private func captureTarget() throws -> (target: CaptureTarget, window: CapturedWindow, name: String) {
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let axWindow = try targetWindow(root: root, app: app)
        guard let target = Self.read(axWindow).frame else {
            throw MacDriverError.noWindow(bundleID)
        }
        let name = app.localizedName ?? bundleID
        let isSheet = Self.read(axWindow).role == "AXSheet"

        if !isSheet, let number = Self.windowNumber(axWindow) {
            return (CaptureTarget(pid: app.processIdentifier, bundleID: bundleID, number: number, frame: target, crop: nil),
                    CapturedWindow(pid: app.processIdentifier, number: number, frame: target), name)
        }

        // A sheet has its own ScreenCaptureKit window, but capturing it returns the whole parent
        // squashed to the sheet's size. The parent is captured, which does show it on top, and the
        // sheet is cropped out: the image lands in the same space as the reading.
        var frame = target
        var crop: CGRect?
        var number: CGWindowID?
        if isSheet,
           let parent: AXUIElement = Self.attribute(axWindow, "AXParent"),
           let parentFrame = Self.read(parent).frame {
            frame = parentFrame
            crop = target.offsetBy(dx: -parentFrame.minX, dy: -parentFrame.minY)
            number = Self.windowNumber(parent)
        }
        return (CaptureTarget(pid: app.processIdentifier, bundleID: bundleID, number: nil, frame: frame, crop: crop),
                CapturedWindow(pid: app.processIdentifier, number: number, frame: frame), name)
    }

    private static func json(_ target: CaptureTarget) throws -> String {
        String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
    }

    func startRecording(to url: URL) async throws {
        var (target, window, _) = try captureTarget()
        // The whole window, sheet included, without the crop a screenshot of a sheet gets.
        target.crop = nil
        try await recorder.start(WindowCapture.helper, ["record", try Self.json(target), url.path], to: url, waitsForReady: true)
        recordedWindow = window
    }

    func stopRecording() async throws -> URL {
        recordedWindow = nil
        return try await recorder.stop()
    }

    // MARK: - AX

    /// The window's origin now, not at the last reading: the user may have moved it since.
    func currentScreenOrigin() async -> CGPoint? {
        // Swallows the window errors, so it must not forget the chosen window either: the
        // action or reading after it reports `windowGone`.
        try? liveWindowOrigin(forgetGone: false)
    }

    /// The target window's origin now. Throws the window errors (`windowGone`,
    /// `ambiguousWindow`); `nil` only when the window reports no frame.
    func liveWindowOrigin(forgetGone: Bool = true) throws -> CGPoint? {
        guard let app = runningApp() else { throw MacDriverError.notRunning(bundleID) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        return Self.read(try targetWindow(root: root, app: app, forgetGone: forgetGone)).frame?.origin
    }

    func runningApp() -> NSRunningApplication? {
        instances(of: bundleID).first
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(element, name as CFString, value)
        guard result == .success else { throw MacDriverError.axFailed(name, result) }
    }

    static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// The window a capture shows: a sheet's parent for a sheet. ScreenCaptureKit follows a window
/// that moves, so the number decides when both have one; the frame otherwise.
nonisolated struct CapturedWindow: Equatable {
    let pid: pid_t
    let number: CGWindowID?
    let frame: CGRect

    func matches(_ other: CapturedWindow) -> Bool {
        guard pid == other.pid else { return false }
        if let number, let otherNumber = other.number { return number == otherNumber }
        return frame == other.frame
    }
}
