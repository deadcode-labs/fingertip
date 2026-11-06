//
//  SimUse.swift
//  FingertipCore
//
//  Envoltorio del CLI `sim-use`. Reemplaza al driver XCUITest de Maestro: acá
//  no hay runner que levantar ni puerto que esperar, solo procesos cortos que
//  devuelven JSON. Las trampas están en CLAUDE.md, sección `### 2. sim-use`.
//

import CoreGraphics
import Foundation

nonisolated enum SimUseError: FingertipError {
    case notInstalled
    case invalidUDID(String)
    case notTypable(String)
    case launchFailed(String)
    case failed(message: String, hint: String?)
    case badResponse(String)
    /// An action only the Mac driver has; nothing was sent.
    case unsupported(String)

    var code: String {
        switch self {
        case .notInstalled: "sim_use_not_installed"
        case .invalidUDID: "invalid_udid"
        case .notTypable: "not_typable"
        case .launchFailed: "sim_use_launch_failed"
        case .failed: "sim_use_failed"
        case .badResponse: "sim_use_bad_response"
        case .unsupported: "unsupported"
        }
    }

    /// sim-use's own failures cover both reads and actions; an action may have landed.
    /// An unsupported action never reached it.
    var retrySafe: Bool {
        if case .unsupported = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "sim-use not found. Install it with `brew install lycorp-jp/tap/sim-use`."
        case .invalidUDID(let udid):
            "Invalid UDID: \(udid)"
        case .notTypable(let characters):
            "Can't type \(characters): the simulator keyboard only takes the US layout. `paste` is no alternative — it needs the simulator's pasteboard, which doesn't sync without Simulator.app."
        case .launchFailed(let detail):
            "Couldn't run sim-use: \(detail)"
        case .failed(let message, let hint):
            hint.map { "\(message)\n\n\($0)" } ?? message
        case .badResponse(let detail):
            "Unexpected response from sim-use: \(detail)"
        case .unsupported(let action):
            "«\(action)» exists only on macOS: on the simulator, tap the control and choose with `tap`."
        }
    }
}

/// Named after the content to see, not where the finger goes, which is the opposite.
/// It is what Jev chooses, so it must read as intent. `caption` goes into Jev's history
/// prompt: it stays as it is.
public nonisolated enum ScrollDirection: String, Sendable {
    case down, up

    public var caption: String {
        switch self {
        case .down: "Deslizar para ver lo de más abajo"
        case .up: "Deslizar para ver lo de más arriba"
        }
    }
}

/// Las acciones de la Fase 3: tap, texto y swipe alcanzan para el 90% de los flujos.
public nonisolated enum DeviceAction: Sendable {
    /// El alias `@N` sale del último `ui` y es la forma preferida de tocar; el
    /// punto queda de respaldo para cuando el elemento no tiene alias.
    case tap(alias: Int?, point: CGPoint)
    case inputText(String)
    case eraseText(characters: Int)
    case swipe(from: CGPoint, to: CGPoint)
    case pressButton(String)
    /// Return en el campo con foco: lo que dispara el `onSubmit` de un formulario.
    case submit
    /// Sets an element's value directly (text, a date, a number) without typing. macOS only.
    case setValue(alias: Int, value: String)
    /// Flips a checkbox, radio button or switch, and checks that it flipped. macOS only.
    case toggle(alias: Int)
    /// Opens the menu of a pop-up or menu button and picks the item with this name. macOS only.
    case select(alias: Int, option: String)

    /// What the UI, the pointer overlay and the MCP reply show. Not part of Jev's history.
    /// `setValue` leaves the value out: it may be a password.
    public var caption: String {
        switch self {
        case .tap(let alias, let point):
            alias.map { "Tap @\($0)" } ?? "Tap (\(Int(point.x)), \(Int(point.y)))"
        case .inputText(let text): "Type \"\(text)\""
        case .eraseText(let count): "Delete \(count) characters"
        case .swipe(let from, let to): "Swipe (\(Int(from.y)) → \(Int(to.y)))"
        case .pressButton(let button): "Button \(button)"
        case .submit: "Return"
        case .setValue(let alias, _): "Set the value of @\(alias)"
        case .toggle(let alias): "Toggle @\(alias)"
        case .select(let alias, let option): "Choose «\(option)» in @\(alias)"
        }
    }

    /// The element the action is aimed at, when it is aimed at one by alias.
    public var alias: Int? {
        switch self {
        case .tap(let alias, _): alias
        case .setValue(let alias, _), .toggle(let alias), .select(let alias, _): alias
        case .inputText, .eraseText, .swipe, .pressButton, .submit: nil
        }
    }

    /// Argumentos de sim-use, sin el device ni `--json`. `nil` for what sim-use cannot do.
    var arguments: [String]? {
        switch self {
        case .tap(let alias, let point):
            if let alias {
                ["tap", "@\(alias)"]
            } else {
                ["tap", "--point", "\(point.x),\(point.y)"]
            }
        case .inputText(let text):
            ["type", text]
        case .eraseText(let characters):
            // No hay verbo de borrado: se mandan N backspaces (HID 42).
            ["ios", "key-sequence", "--keycodes",
             Array(repeating: "42", count: characters).joined(separator: ",")]
        case .swipe(let from, let to):
            // `describe-ui` imprime en espacio 'ui'; el default de swipe es
            // 'native', que solo coincide en portrait.
            ["swipe",
             "--from", "\(from.x),\(from.y)",
             "--to", "\(to.x),\(to.y)",
             "--duration", "0.4",
             "--coordinate-space", "ui"]
        case .pressButton(let button):
            ["button", button]
        case .submit:
            ["ios", "key-sequence", "--keycodes", "40"]
        case .setValue, .toggle, .select:
            nil
        }
    }

    /// `type` manda keycodes de teclado US: los acentos y la ñ no tienen uno, y
    /// sim-use corta con "No keycode found for character". Se valida antes para
    /// decir cuáles son y que no hay alternativa, en vez del error en inglés.
    private static let typable = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !@#$%^&*()_+-={}[]|\\:\";'<>?,./`~"
    )

    /// Caracteres del texto que el teclado del simulador no puede producir.
    public static func untypable(in text: String) -> String {
        String(Set(text.filter { !typable.contains($0) }).sorted())
    }

    /// Swipe vertical por el medio de la pantalla. Para ver lo que está más
    /// abajo el dedo sube, así que el recorrido va con el signo invertido.
    public static func scroll(_ direction: ScrollDirection, screen: CGSize) -> DeviceAction {
        let size = screen == .zero ? CGSize(width: 390, height: 844) : screen
        let travel = size.height * 0.35 * (direction == .down ? -1 : 1)
        let midX = size.width / 2
        let midY = size.height / 2
        return .swipe(from: CGPoint(x: midX, y: midY), to: CGPoint(x: midX, y: midY + travel))
    }
}

public actor SimUse {
    /// Una app lanzada desde Finder o Xcode hereda un PATH mínimo que no
    /// incluye los prefijos de Homebrew, así que no alcanza con buscar en PATH.
    private static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    private var cachedBinary: URL?

    /// 8-4-4-4-12 hexadecimal. El UDID va como argv, no por shell, pero igual se
    /// valida antes de pasárselo a un proceso.
    private static func isValidUDID(_ udid: String) -> Bool {
        let groups = udid.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard groups.count == lengths.count else { return false }
        return zip(groups, lengths).allSatisfy { group, length in
            group.count == length && group.allSatisfy(\.isHexDigit)
        }
    }

    // MARK: - Disponibilidad

    /// `nil` si no está instalado: la UI lo muestra en vez de reventar.
    func binaryPath() -> String? { try? locate().path }

    private func locate() throws -> URL {
        if let cachedBinary { return cachedBinary }
        guard let found = Self.installedBinary() else { throw SimUseError.notInstalled }
        cachedBinary = found
        return found
    }

    /// Searches without caching, so the app's onboarding sees an install that just finished.
    public nonisolated static func installedBinary() -> URL? {
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (fromPath + fallbackDirectories)
            .map { URL(filePath: $0).appending(path: "sim-use") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Lectura de pantalla

    /// `--no-raw` saca el árbol crudo: son 23 KB contra 2 KB y no lo usamos.
    func describeUI(udid: String) async throws -> ScreenHierarchy {
        let data = try await run(["ui", "--json", "--no-raw"], udid: udid)
        do {
            let envelope = try JSONDecoder().decode(SimUseEnvelope<SimUseScreenData>.self, from: data)
            guard let screen = envelope.data else {
                throw SimUseError.badResponse("envelope without data")
            }
            return ScreenHierarchy(screen, vanished: envelope.vanishedApps)
        } catch let error as SimUseError {
            throw error
        } catch {
            throw SimUseError.badResponse(String(decoding: data.prefix(400), as: UTF8.self))
        }
    }

    // MARK: - Acciones

    func perform(_ action: DeviceAction, udid: String) async throws {
        if case .inputText(let text) = action {
            let rejected = DeviceAction.untypable(in: text)
            guard rejected.isEmpty else { throw SimUseError.notTypable(rejected) }
        }
        guard let arguments = action.arguments else { throw SimUseError.unsupported(action.caption) }
        _ = try await run(arguments + ["--json"], udid: udid)
    }

    /// El daemon se va solo a los 600 s, pero pararlo explícitamente deja el
    /// simulador libre cuando el usuario termina.
    func stopDaemon(udid: String) async {
        _ = try? await run(["daemon", "stop"], udid: udid)
    }

    // MARK: - Proceso

    /// sim-use manda JSON por stdout tanto en éxito como en error, y usa el
    /// exit code solo como señal redundante: se ramifica por `ok`, no por status.
    private func run(_ arguments: [String], udid: String) async throws -> Data {
        guard Self.isValidUDID(udid) else {
            throw SimUseError.invalidUDID(udid)
        }
        let binary = try locate()

        let result: SubprocessOutput
        do {
            result = try await Subprocess.run(
                binary, arguments + ["--device", udid],
                // The subcommand only: `type`'s argument is the text, maybe a password.
                label: "sim-use \(arguments.first ?? "")",
                timeout: Self.timeout, isRead: arguments.first == "ui"
            )
        } catch let timeout as SubprocessTimeout {
            throw timeout
        } catch {
            throw SimUseError.launchFailed(error.localizedDescription)
        }

        if let failure = try? JSONDecoder().decode(SimUseFailure.self, from: result.stdout), !failure.ok {
            throw SimUseError.failed(message: failure.error, hint: failure.hint)
        }
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimUseError.badResponse(stderr.isEmpty ? "exit \(result.status)" : stderr)
        }
        return result.stdout
    }

    /// A reading takes ~0.5 s warm and ~1.5 s when it starts the daemon. Thirty seconds is
    /// past anything that is still working; a stuck XCUITest driver never answers at all.
    private static let timeout: Duration = .seconds(30)
}

// MARK: - Envelope

nonisolated struct SimUseEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    var ok: Bool
    var data: T?
    /// sim-use vigila los procesos entre llamadas y avisa acá cuando uno se fue.
    var process: ProcessReport?

    /// `events` aparece una sola vez, en la lectura siguiente a la muerte del
    /// proceso; `pending` sigue ahí hasta que la app vuelve a arrancar, que es
    /// lo que hace falta para cortar una corrida.
    var vanishedApps: [String] {
        (process?.pending ?? [])
            .filter { $0.kind == "disappeared" }
            .map(\.bundleId)
    }

    nonisolated struct ProcessReport: Decodable, Sendable {
        var pending: [Event]

        nonisolated struct Event: Decodable, Sendable {
            var bundleId: String
            var kind: String
        }
    }
}

/// El envelope de error trae `error` y un `hint` que lista los labels visibles:
/// es justo lo que hay que mostrarle al usuario para re-apuntar.
nonisolated struct SimUseFailure: Decodable, Sendable {
    var ok: Bool
    var error: String
    var hint: String?
}
