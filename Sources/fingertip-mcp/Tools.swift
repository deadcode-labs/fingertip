//
//  Tools.swift
//  fingertip-mcp
//
//  Las tools que ve Claude Code. Son las mismas piezas que usa la app —
//  `ScreenInspector` sobre un `ScreenDriver`, y `JevAgent` para delegar una
//  corrida entera—, así que un simulador y una app de macOS se manejan igual.
//
//  Toda acción relee la pantalla y la devuelve: los alias `@N` salen de la
//  última lectura, y tocar sin releer apunta a la pantalla anterior.
//

import AppKit
import FingertipCore
import ImageIO
import UniformTypeIdentifiers

/// Failures of the tools themselves, before or around the device.
nonisolated enum ToolError: FingertipError {
    case invalidArguments(String)
    case blockedApp(String)
    case notConnected(String)
    case appNotFound(String)
    case appVanished(String)
    case timedOut(String)
    case bringToFrontDisabled

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .blockedApp: "blocked_app"
        case .notConnected: "not_connected"
        case .appNotFound: "app_not_found"
        case .appVanished: "app_vanished"
        case .timedOut: "timed_out"
        case .bringToFrontDisabled: "bring_to_front_disabled"
        }
    }

    /// Waiting again is harmless; the rest need a different call or the user.
    var retrySafe: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .blockedApp(let message), .notConnected(let message),
             .appNotFound(let message), .appVanished(let message), .timedOut(let message):
            message
        case .bringToFrontDisabled:
            "Traer ventanas al frente está desactivado: lo activa la persona en Fingertip → Ajustes → General → Ventanas. No hace falta reconectar."
        }
    }
}

extension ToolResult {
    static func invalid(_ message: String) -> ToolResult {
        .error(ToolError.invalidArguments(message))
    }
}

final class Session {
    private let inspector = ScreenInspector()

    /// Closes what outlives a call: a recording left open would leave an unplayable `.mov`.
    func shutdown() async {
        await inspector.disconnect()
    }
    private lazy var agent = JevAgent(inspector: inspector)
    private let simctl = Simctl()
    private var target: Target?
    /// Region `read_screen` was pointed at; every outline shows only it until a whole read.
    private var focusRegion: String?
    /// Past this many elements the outline suggests reading by region.
    private static let denseThreshold = 150

    /// Lado mayor de la imagen que vuelve inline. La captura completa queda en
    /// disco: una ventana retina en PNG pesa megas y no aporta para decidir.
    private static let inlineImageSide = 1280

    var tools: [Tool] {
        [
            Tool(
                name: "list_targets",
                description: "Lista los simuladores iOS (UDID, runtime, si están booteados) y las apps de macOS que están corriendo. Es el punto de partida para elegir qué probar con `connect`.",
                handler: { _ in await self.listTargets() }
            ),
            Tool(
                name: "connect",
                description: "Elige el dispositivo sobre el que actúan las demás tools y devuelve su pantalla. Pasá `udid` para un simulador (se bootea si hace falta) o `bundle_id` para una app de macOS (se abre si no está corriendo; `app_path` desambigua cuando hay dos copias, p. ej. la build de Xcode y la de /Applications). Si hay un único simulador booteado, las demás tools se conectan solas.",
                properties: [
                    "udid": ["type": "string", "description": "UDID del simulador."],
                    "bundle_id": ["type": "string", "description": "Bundle id de la app de macOS."],
                    "app_path": ["type": "string", "description": "Ruta al .app, cuando hay más de una copia con el mismo bundle id."]
                ],
                handler: { await self.connect($0) }
            ),
            Tool(
                name: "read_screen",
                description: "Lee la pantalla actual como lista de elementos agrupados por región: `@L:N Tipo \"rótulo\" #identifier (x,y anchoxalto)`, donde L es el número de lectura y N el elemento. `tap` acepta el alias completo; si la pantalla cambió antes de ese elemento, lo rechaza en vez de tocar otra cosa. Los textos largos vienen cortados en una línea con «…»; `full: true` los trae enteros. En una pantalla densa, `skeleton: true` trae solo las regiones con cuántos elementos tiene cada una, y `region` muestra una sola: las acciones siguientes también muestran solo esa, hasta un `read_screen` sin `region`. Si una app de macOS tiene varias ventanas, falla con `ambiguous_window` hasta que elijas una con `window` (el número de `list_windows`); la elección queda para las tools siguientes.",
                properties: [
                    "full": ["type": "boolean", "description": "Textos completos, sin cortar."],
                    "skeleton": ["type": "boolean", "description": "Solo las regiones y cuántos elementos tiene cada una."],
                    "region": ["type": "string", "description": "Nombre de la región a mostrar, tal como aparece entre corchetes."],
                    "window": ["type": "integer", "description": "macOS: número de ventana de `list_windows`. Lee esa y la deja elegida."]
                ],
                handler: { await self.readScreen($0) }
            ),
            Tool(
                name: "list_windows",
                description: "macOS: las ventanas de la app conectada, con su número, título y posición, y cuál tiene el foco y cuál está elegida. Elegí una con `read_screen` y `window`.",
                handler: { _ in await self.listWindows() }
            ),
            Tool(
                name: "bring_to_front",
                description: "macOS: trae al frente una ventana de la app y la deja elegida; si está en otro escritorio, cambia a ese escritorio (lo que ve la persona cambia). Sin `window`, la elegida o la única. Devuelve la pantalla. Solo funciona si la persona lo permitió en Fingertip → Ajustes; si no, falla con `bring_to_front_disabled`.",
                properties: [
                    "window": ["type": "integer", "description": "Número de ventana de `list_windows`."]
                ],
                handler: { await self.bringToFront($0) }
            ),
            Tool(
                name: "wait_for",
                description: "Espera dentro del servidor, sin devolverte el turno, a que aparezca un elemento cuyo texto, rótulo o #identifier contenga `text` (sin distinguir mayúsculas ni acentos), y devuelve la pantalla apenas aparece. Revisa cada ~0,25 s. Con `tap: true` lo toca en el acto: es la forma de alcanzar lo que dura poco, como una card de aprobación. Con `gone: true` espera a que desaparezca (p. ej. un «Trabajando…»). Si hay varios, gana el que coincide exacto y, entre esos, un botón.",
                properties: [
                    "text": ["type": "string"],
                    "tap": ["type": "boolean", "description": "Tocarlo apenas aparece."],
                    "gone": ["type": "boolean", "description": "Esperar a que desaparezca en vez de a que aparezca."],
                    "timeout": ["type": "number", "description": "Segundos; por defecto 30, máximo 120."]
                ],
                required: ["text"],
                handler: { await self.waitFor($0) }
            ),
            Tool(
                name: "tap",
                description: "Toca un elemento por su alias `@L:N` (preferido) o por coordenadas `x`,`y` en el espacio de la lectura. Antes de tocar relee la pantalla: si cambió algo hasta ese elemento, no toca y devuelve la pantalla nueva para elegir de nuevo. Devuelve la pantalla resultante. En un campo de texto, tocar le da el foco: después usá `type_text`. En macOS, tocar un pop-up abre su menú y la lectura lista sus ítems en la región «Menú» (`Mode › Scientific`); tocar uno lo elige, y tocar de nuevo el pop-up lo cierra. La línea «Entrega» dice qué se intentó y qué se verificó: `sin efecto` es que la app aceptó la acción y no cambió nada.",
                properties: [
                    "alias": ["type": "string", "description": "El alias completo, como aparece en la lectura: `12:5` es el elemento 5 de la lectura 12."],
                    "x": ["type": "number"],
                    "y": ["type": "number"]
                ],
                handler: { await self.tap($0) }
            ),
            Tool(
                name: "select",
                description: "macOS: abre el menú de un pop-up o botón con menú (`alias`), elige el ítem `option` (sin distinguir mayúsculas ni acentos) y relee el control. Si no hay ese ítem, cierra el menú y lista las opciones. Si ya hay un menú abierto, lo rechaza con `menu_already_open`.",
                properties: [
                    "alias": ["type": "string", "description": "El alias completo del control, `12:5`."],
                    "option": ["type": "string", "description": "El texto del ítem del menú."]
                ],
                required: ["alias", "option"],
                handler: { await self.select($0) }
            ),
            Tool(
                name: "set_value",
                description: "macOS: escribe el valor de un control de una vez, sin teclear: texto en un campo, una fecha en un date picker (`yyyy-MM-dd HH:mm`, `yyyy-MM-dd` o `HH:mm`, hora local), un número en un slider. Relee el valor; si no cambió, falla con `no_effect`. Un elemento de solo lectura da `not_settable`.",
                properties: [
                    "alias": ["type": "string", "description": "El alias completo del control, `12:5`."],
                    "value": ["type": "string"]
                ],
                required: ["alias", "value"],
                handler: { await self.setValue($0) }
            ),
            Tool(
                name: "toggle",
                description: "macOS: alterna un checkbox, radio o switch y verifica que cambió (AXPress, después AXValue, después un clic real).",
                properties: ["alias": ["type": "string", "description": "El alias completo del control, `12:5`."]],
                required: ["alias"],
                handler: { await self.toggle($0) }
            ),
            Tool(
                name: "type_text",
                description: "Escribe en el campo con foco (tocalo antes). En el simulador solo hay teclado US: sin acentos, ñ ni símbolos fuera de ASCII. En macOS acepta cualquier texto.",
                properties: ["text": ["type": "string"]],
                required: ["text"],
                handler: { await self.typeText($0) }
            ),
            Tool(
                name: "erase_text",
                description: "Borra `count` caracteres del campo con foco, desde el final.",
                properties: ["count": ["type": "integer", "minimum": 1]],
                required: ["count"],
                handler: { await self.eraseText($0) }
            ),
            Tool(
                name: "submit",
                description: "Aprieta Return en el campo con foco, sin salir de él: dispara el envío del formulario (el `onSubmit`). Tocá el campo antes.",
                handler: { _ in await self.perform(.submit) }
            ),
            Tool(
                name: "scroll",
                description: "Desplaza el contenido. `down` muestra lo que está más abajo, `up` lo que está más arriba. La lectura solo trae lo visible: si lo que buscás no aparece, scrolleá.",
                properties: ["direction": ["type": "string", "enum": ["down", "up"]]],
                required: ["direction"],
                handler: { await self.scroll($0) }
            ),
            Tool(
                name: "swipe",
                description: "Desliza entre dos puntos en el espacio de la lectura (carruseles, gestos de cerrar). Para scroll vertical común, `scroll` es más simple.",
                properties: [
                    "from_x": ["type": "number"], "from_y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"]
                ],
                required: ["from_x", "from_y", "to_x", "to_y"],
                handler: { await self.swipe($0) }
            ),
            Tool(
                name: "press_button",
                description: "Botón de hardware del simulador. No existe en macOS.",
                properties: ["button": ["type": "string", "enum": ["home", "lock", "side-button", "siri", "apple-pay"]]],
                required: ["button"],
                handler: { await self.pressButton($0) }
            ),
            Tool(
                name: "screenshot",
                description: "Captura de la pantalla del simulador o de la ventana de la app. Devuelve la imagen reducida y la ruta del PNG completo. Úsala para verificar lo visual (layout, colores, imágenes); para saber qué hay y qué tocar, `read_screen` es más barato.",
                handler: { _ in await self.screenshot() }
            ),
            Tool(
                name: "start_recording",
                description: "Empieza a grabar un video (.mov, sin audio) del simulador o de la ventana de la app. Una sola grabación a la vez; las acciones siguientes (tap, scroll…) quedan en el video. Termínala con `stop_recording`.",
                handler: { _ in await self.startRecording() }
            ),
            Tool(
                name: "stop_recording",
                description: "Termina la grabación en curso y devuelve la ruta del .mov. Al desconectar o cerrar el servidor con una grabación abierta, también se cierra el archivo.",
                handler: { _ in await self.stopRecording() }
            ),
            Tool(
                name: "relaunch_app",
                description: "Mata la app y la vuelve a abrir, y espera a que su pantalla esté lista (hasta 15 s). Sirve para arrancar cada prueba desde la pantalla inicial. Una app de macOS corriendo bajo el depurador de Xcode no se relanza.",
                properties: ["bundle_id": ["type": "string"]],
                required: ["bundle_id"],
                handler: { await self.relaunchApp($0) }
            ),
            Tool(
                name: "terminate_app",
                description: "Cierra la app (forzado).",
                properties: ["bundle_id": ["type": "string"]],
                required: ["bundle_id"],
                handler: { await self.terminateApp($0) }
            ),
            Tool(
                name: "run_instruction",
                description: "Delega una instrucción entera a Jev (TypeSafe System One): elige y ejecuta pasos hasta que la da por cumplida, se queda sin confianza (`needs_user`) o llega a 10 pasos. Con `bundle_id`, relanza la app antes de empezar. Devuelve el resultado, los pasos y la ruta del log JSONL con capturas. Necesita TYPESAFE_API_KEY en el entorno del servidor.",
                properties: [
                    "instruction": ["type": "string", "description": "Qué hacer, en lenguaje natural. El texto a escribir va entre comillas."],
                    "bundle_id": ["type": "string", "description": "App bajo prueba; vacío arranca desde donde esté."]
                ],
                required: ["instruction"],
                handler: { await self.runInstruction($0) }
            )
        ]
    }

    // MARK: - Status toast

    /// The call in a few words, for the Fingertip app's toast. Data, so in Spanish.
    func status(_ tool: String, _ arguments: [String: Any]) -> String {
        func quoted(_ text: String) -> String {
            "«\(text.count > 40 ? text.prefix(39) + "…" : text)»"
        }
        let text = arguments["text"] as? String ?? ""
        switch tool {
        case "list_targets": return "Buscando dispositivos"
        case "connect": return "Conectando a \(arguments["bundle_id"] as? String ?? arguments["udid"] as? String ?? "un dispositivo")"
        case "read_screen": return "Leyendo la pantalla"
        case "wait_for": return (arguments["gone"] as? Bool ?? false) ? "Esperando que se vaya \(quoted(text))" : "Esperando \(quoted(text))"
        case "tap": return "Tocando \(tapTarget(arguments))"
        case "select": return "Eligiendo \(quoted(arguments["option"] as? String ?? "")) en \(tapTarget(arguments))"
        // The value may be a password, like typed text.
        case "set_value": return "Cambiando el valor de \(tapTarget(arguments))"
        case "toggle": return "Alternando \(tapTarget(arguments))"
        case "list_windows": return "Listando ventanas"
        case "bring_to_front": return "Trayendo la ventana al frente"
        // Typed text and instructions may carry a password: the toast is on screen and in recordings.
        case "type_text": return "Escribiendo \(text.count) caracteres"
        case "erase_text": return "Borrando \(arguments["count"] as? Int ?? 0) caracteres"
        case "submit": return "Return"
        case "scroll": return (arguments["direction"] as? String) == "up" ? "Scrolleando hacia arriba" : "Scrolleando hacia abajo"
        case "swipe": return "Deslizando"
        case "press_button": return "Botón \(arguments["button"] as? String ?? "")"
        case "screenshot": return "Capturando la pantalla"
        case "start_recording": return "Empezando a grabar"
        case "stop_recording": return "Terminando la grabación"
        case "relaunch_app": return "Relanzando \(arguments["bundle_id"] as? String ?? "la app")"
        case "terminate_app": return "Cerrando \(arguments["bundle_id"] as? String ?? "la app")"
        case "run_instruction": return "Jev: corriendo una instrucción"
        default: return tool
        }
    }

    /// The element's caption when the alias is from the current reading.
    private func tapTarget(_ arguments: [String: Any]) -> String {
        guard let alias = arguments["alias"] as? String else { return "un punto" }
        let parts = alias.trimmingCharacters(in: CharacterSet(charactersIn: "@")).split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, parts[0] == inspector.reading,
           let element = inspector.elements.first(where: { $0.alias == parts[1] }) {
            return "«\(element.caption)»"
        }
        return "@\(alias)"
    }

    // MARK: - Apps bloqueadas

    /// The list lives in `BlockedApps`; the user edits it in the app's Security pane.
    /// God mode is decided when registering the server, not by Claude: a tool argument
    /// could be passed by the same injected instruction the block is meant to stop.
    private static let isUnrestricted = ProcessInfo.processInfo.environment["FINGERTIP_UNRESTRICTED"] == "1"

    /// Reads the settings on every call: the app may change the list while the MCP runs.
    private static func isBlocked(_ bundleID: String, settings: FingertipSettings = .load()) -> Bool {
        BlockedApps.isBlocked(bundleID, unrestricted: isUnrestricted, settings: settings)
    }

    private static func blockedError(_ bundleID: String) -> ToolResult {
        .error(ToolError.blockedApp("""
        \(bundleID) está bloqueada: escribir en ella puede correr comandos o exponer secretos. \
        Solo el usuario puede liberarla, en Ajustes de Fingertip → Seguridad o registrando el servidor con `-e FINGERTIP_UNRESTRICTED=1`.
        """))
    }

    // MARK: - Dispositivo

    private func listTargets() async -> ToolResult {
        var lines: [String] = ["Simuladores:"]
        var booted: Set<String>?
        do {
            let devices = try await simctl.listDevices()
            lines += devices.map { "  \($0.name) — \($0.runtime) — \($0.udid)\($0.isBooted ? " — booteado" : "")" }
            booted = Set(devices.filter(\.isBooted).map(\.udid))
        } catch {
            lines.append("  (no pude listarlos: \(Self.describe(error)))")
        }
        lines.append("")
        lines.append("Apps de macOS corriendo:")
        let apps = MacApp.running()
        let settings = FingertipSettings.load()
        lines += apps.map { "  \($0.name) — \($0.bundleID) — \($0.bundleURL.path)\(Self.isBlocked($0.bundleID, settings: settings) ? " — bloqueada" : "")" }
        if let target {
            // La conexión no se entera si la app se cerró o el simulador se apagó:
            // decirlo acá evita que alguien crea que sigue apuntando a algo vivo.
            let alive = switch target {
            case .simulator(let udid): booted?.contains(udid) ?? true
            case .mac(let app): apps.contains(app)
            }
            lines += ["", alive
                ? "Conectado a: \(Self.describe(target))"
                : "Conectado a: \(Self.describe(target)) — ya no está corriendo; usá `connect`."]
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func connect(_ arguments: [String: Any]) async -> ToolResult {
        let udid = arguments["udid"] as? String
        let bundleID = arguments["bundle_id"] as? String
        guard (udid == nil) != (bundleID == nil) else {
            return .invalid("Pasá `udid` (simulador) o `bundle_id` (app de macOS), uno de los dos.")
        }

        let target: Target
        if let udid {
            do {
                try await simctl.boot(udid: udid)
            } catch {
                return .error(fingertipError(error))
            }
            target = .simulator(udid: udid)
        } else {
            if Self.isBlocked(bundleID!) { return Self.blockedError(bundleID!) }
            guard let app = Self.macApp(bundleID: bundleID!, path: arguments["app_path"] as? String) else {
                return .error(ToolError.appNotFound("No encontré \(bundleID!) corriendo ni instalado (o `app_path` es otra app)."))
            }
            // Se chequea también lo resuelto: lo que se abre es la app, no el texto pedido.
            if Self.isBlocked(app.bundleID) { return Self.blockedError(app.bundleID) }
            let running = MacApp.running().contains(app)
            target = .mac(app)
            if !running {
                do {
                    try await target.makeDriver().launch(bundleID: app.bundleID)
                } catch {
                    return .error(fingertipError(error))
                }
            }
        }
        return await connect(to: target)
    }

    private func connect(to target: Target) async -> ToolResult {
        // Switching devices closes a recording in progress; say so, or the agent loses the file.
        let closed = inspector.driver != nil ? await inspector.disconnect() : nil
        let closedNote = closed.map { "Se cerró la grabación en curso al cambiar de dispositivo: \($0.path)\n\n" } ?? ""
        // An agent must say which window it means: "the focused one" is whatever the user clicked last.
        await inspector.connect(target)
        guard inspector.connectionState == .ready else {
            return .error(inspector.failure ?? ToolError.notConnected("No pude conectarme."))
        }
        self.target = target
        focusRegion = nil
        let connected = "\(closedNote)Conectado a \(Self.describe(target)) vía \(inspector.driver?.name ?? "?")."
        // Connected, but nothing read yet: the error names the windows to choose from.
        if let failure = inspector.failure { return .error(failure, appending: connected) }
        return .text("\(connected)\n\n\(outline())")
    }

    /// La que corre gana sobre la instalada: es la que el usuario está mirando.
    /// Entre dos copias corriendo, la ruta decide; sin ruta, la primera.
    private static func macApp(bundleID: String, path: String?) -> MacApp? {
        // Un .app es un directorio: sin el hint, la URL queda sin `/` final y no
        // es igual a la de `NSRunningApplication.bundleURL`, que sí la tiene.
        let wanted = path.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        if let running = MacApp.running().first(where: { $0.bundleID == bundleID && (wanted == nil || $0.bundleURL == wanted) }) {
            return running
        }
        guard let url = wanted ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        // `app_path` manda en lo que se abre: si apunta a otra app, se rechaza
        // en vez de lanzar esa con el bundle id pedido como disfraz.
        guard let actual = Bundle(url: url)?.bundleIdentifier,
              actual.caseInsensitiveCompare(bundleID) == .orderedSame
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return MacApp(bundleID: actual, name: name, bundleURL: url.standardizedFileURL)
    }

    /// Con un único simulador booteado no hace falta elegir: es el caso común.
    private func ensureConnected() async -> ToolResult? {
        if inspector.driver != nil { return nil }
        let booted = ((try? await simctl.listDevices()) ?? []).filter(\.isBooted)
        guard booted.count == 1 else {
            return .error(ToolError.notConnected("No hay dispositivo conectado y hay \(booted.count) simuladores booteados: usá `list_targets` y `connect`."))
        }
        let result = await connect(to: .simulator(udid: booted[0].udid))
        return result.isError ? result : nil
    }

    // MARK: - Pantalla

    private func readScreen(_ arguments: [String: Any]) async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        if let raw = arguments["window"] {
            guard let number = Self.int(raw) else { return .invalid("`window` es el número de `list_windows`.") }
            await inspector.chooseWindow(number: number)
        } else {
            await inspector.readScreen()
        }
        if let failure = inspector.failure { return .error(failure) }
        let skeleton = arguments["skeleton"] as? Bool ?? false
        if let region = arguments["region"] as? String, !region.isEmpty, !skeleton {
            guard inspector.regions.contains(region) else {
                return .invalid("No hay región «\(region)». Están: \(inspector.regions.map { "«\($0)»" }.joined(separator: ", ")).")
            }
            focusRegion = region
        } else {
            focusRegion = nil
        }
        return .text(outline(full: arguments["full"] as? Bool ?? false, skeleton: skeleton))
    }

    /// Lee en loop hasta que el elemento aparece (o desaparece). Esperar acá y no
    /// en el modelo es todo el punto: una vuelta de Claude tarda segundos, una
    /// lectura menos de 0,1 s en macOS y ~0,5 s en el simulador.
    private func waitFor(_ arguments: [String: Any]) async -> ToolResult {
        guard let query = arguments["text"] as? String, !query.isEmpty else { return .invalid("Falta `text`.") }
        let shouldTap = arguments["tap"] as? Bool ?? false
        let gone = arguments["gone"] as? Bool ?? false
        guard !(shouldTap && gone) else { return .invalid("`tap` y `gone` no van juntos.") }
        let seconds = min(max(Self.double(arguments["timeout"]) ?? 30, 1), 120)
        if let failure = await ensureConnected() { return failure }

        let start = ContinuousClock.now
        let deadline = start + .seconds(seconds)
        while true {
            await inspector.readScreen()
            if let failure = inspector.failure { return .error(failure) }
            if !inspector.vanishedApps.isEmpty {
                return .error(ToolError.appVanished("La app dejó de correr mientras esperaba «\(query)»."), appending: outline())
            }
            let match = Self.match(query, in: inspector.elements, toTap: shouldTap)
            let waited = (ContinuousClock.now - start).components
            let elapsed = String(format: "%.1f", Double(waited.seconds) + Double(waited.attoseconds) / 1e18)

            if gone, match == nil {
                return .text("«\(query)» ya no está (\(elapsed) s).\n\n\(outline())")
            }
            if !gone, let match {
                guard shouldTap else { return .text("Apareció «\(query)» (\(elapsed) s).\n\n\(outline())") }
                await inspector.perform(match.tapAction)
                if let failure = inspector.failure { return .error(failure) }
                return .text("Apareció «\(query)» (\(elapsed) s) y lo toqué: \(match.type) \"\(Self.clipped(match.caption))\".\n\n\(outline())")
            }
            guard ContinuousClock.now < deadline else {
                let what = gone ? "«\(query)» sigue en pantalla" : "No apareció «\(query)»"
                return .error(ToolError.timedOut("\(what) después de \(Int(seconds)) s."), appending: outline())
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Exacto antes que parcial y, a igualdad, un botón antes que un texto. Para
    /// tocar, un texto que solo *contiene* la palabra no cuenta: «Aprobar» suele
    /// estar también en el cuerpo del mensaje, que existe antes que la card.
    private static func match(_ query: String, in elements: [UIElement], toTap: Bool = false) -> UIElement? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func fields(_ e: UIElement) -> [String] { [e.label, e.text, e.identifier].compactMap { $0 } }
        func isExact(_ e: UIElement) -> Bool { fields(e).contains { $0.compare(query, options: options) == .orderedSame } }
        func isProse(_ e: UIElement) -> Bool { ["StaticText", "TextView", "Image"].contains(e.type) }
        let hits = elements.filter { e in
            fields(e).contains { $0.range(of: query, options: options) != nil } && (!toTap || isExact(e) || !isProse(e))
        }
        func rank(_ e: UIElement) -> Int { (isExact(e) ? 0 : 2) + (e.type.contains("Button") ? 0 : 1) }
        return hits.min { rank($0) < rank($1) }
    }

    /// El mismo formato que el outline de sim-use, que es lo que mejor se lee.
    private func outline(full: Bool = false, skeleton: Bool = false) -> String {
        let size = inspector.screenSize
        var lines = ["App: \(inspector.appLabel ?? "?") (\(inspector.appPackage ?? "?"))  \(Int(size.width))x\(Int(size.height))  · lectura \(inspector.reading)"]
        if !inspector.vanishedApps.isEmpty {
            lines.append("⚠ Dejaron de correr desde la lectura anterior (¿crash?): \(inspector.vanishedApps.joined(separator: ", "))")
        }
        if let focus = focusRegion, !inspector.regions.contains(focus) { focusRegion = nil }
        for region in inspector.regions {
            let members = inspector.elements(in: region)
            if skeleton || (focusRegion != nil && region != focusRegion) {
                lines.append("[\(region)] \(members.count) elementos")
            } else {
                lines.append("[\(region)]")
                lines += members.map { line($0, full: full) }
            }
        }
        if inspector.elements.isEmpty { lines.append("(sin elementos)") }
        if skeleton {
            lines.append("Para ver una región: `read_screen` con `region`.")
        } else if let focus = focusRegion {
            lines.append("Mostrando solo «\(focus)»; `read_screen` sin `region` vuelve a la pantalla entera.")
        } else if inspector.elements.count > Self.denseThreshold {
            lines.append("Pantalla densa (\(inspector.elements.count) elementos): `read_screen` con `skeleton: true` y después `region` cuesta menos.")
        }
        return lines.joined(separator: "\n")
    }

    private func line(_ element: UIElement, full: Bool) -> String {
        let show: (String) -> String = full ? { $0 } : { Self.clipped($0) }
        var parts = [element.alias.map { "@\(inspector.reading):\($0)" } ?? "--", element.type]
        if let label = element.label { parts.append("\"\(show(label))\"") }
        if let text = element.text { parts.append(element.label == nil ? "\"\(show(text))\"" : "= \"\(show(text))\"") }
        if let identifier = element.identifier { parts.append("#\(identifier)") }
        let b = element.bounds
        parts.append("(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)))")
        if !element.isEnabled { parts.append("[deshabilitado]") }
        if let checked = element.isChecked { parts.append(checked ? "[marcado]" : "[desmarcado]") }
        return "  " + parts.joined(separator: "  ")
    }

    /// Una línea y hasta 100 caracteres. Cada acción devuelve la pantalla entera,
    /// y la respuesta de un chat puede ser una página: cortada se reconoce igual,
    /// y `read_screen` con `full` la trae completa cuando hay que leerla.
    private static func clipped(_ text: String, limit: Int = 100) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        guard flat.count > limit else { return flat }
        return "\(flat.prefix(limit))… (\(text.count) caracteres)"
    }

    // MARK: - Windows

    private func listWindows() async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        guard case .mac(let app)? = target else { return .invalid("`list_windows` es para apps de macOS: el simulador tiene una sola pantalla.") }
        let windows: [WindowInfo]
        do {
            windows = try await inspector.listWindows()
        } catch {
            return .error(fingertipError(error))
        }
        guard !windows.isEmpty else { return .text("\(app.name) no tiene ventanas.") }
        var lines = ["Ventanas de \(app.name) (\(app.bundleID)):"]
        lines += windows.map { window in
            let f = window.frame
            var parts = ["  \(window.caption)", "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"]
            if window.isFocused { parts.append("[en foco]") }
            if window.isChosen { parts.append("[elegida]") }
            if window.isMinimized { parts.append("[minimizada]") }
            if window.isOnOtherSpace { parts.append("[en otro escritorio]") }
            return parts.joined(separator: "  ")
        }
        lines.append("Elegí una con `read_screen` y `window: <número>`.")
        return .text(lines.joined(separator: "\n"))
    }

    private func bringToFront(_ arguments: [String: Any]) async -> ToolResult {
        guard FingertipSettings.load().bringToFrontEnabled else { return .error(ToolError.bringToFrontDisabled) }
        if let failure = await ensureConnected() { return failure }
        guard case .mac? = target else { return .invalid("`bring_to_front` es para apps de macOS: el simulador tiene una sola pantalla.") }
        var window: Int?
        if let raw = arguments["window"] {
            guard let number = Self.int(raw) else { return .invalid("`window` es el número de `list_windows`.") }
            window = number
        }
        await inspector.bringToFront(window: window)
        if let failure = inspector.failure { return .error(failure) }
        focusRegion = nil
        return .text(outline())
    }

    // MARK: - Acciones

    private func tap(_ arguments: [String: Any]) async -> ToolResult {
        if let raw = arguments["alias"] {
            guard let (reading, alias) = Self.alias(raw) else {
                return .invalid("`alias` va completo, como aparece en la lectura: `12:5` es el elemento 5 de la lectura 12.")
            }
            if let failure = await ensureConnected() { return failure }
            await inspector.tap(alias: alias, seenIn: reading)
            return finished("Tocar @\(reading):\(alias)")
        }
        guard let x = Self.double(arguments["x"]), let y = Self.double(arguments["y"]) else {
            return .invalid("Pasá `alias`, o `x` e `y`.")
        }
        return await perform(.tap(alias: nil, point: CGPoint(x: x, y: y)))
    }

    private func select(_ arguments: [String: Any]) async -> ToolResult {
        guard let option = arguments["option"] as? String, !option.isEmpty else { return .invalid("Falta `option`.") }
        return await act(arguments, caption: "Elegir «\(option)»") { element in
            element.alias.map { .select(alias: $0, option: option) }
        }
    }

    private func setValue(_ arguments: [String: Any]) async -> ToolResult {
        guard let value = arguments["value"] as? String else { return .invalid("Falta `value`.") }
        return await act(arguments, caption: "Cambiar el valor") { element in
            element.alias.map { .setValue(alias: $0, value: value) }
        }
    }

    private func toggle(_ arguments: [String: Any]) async -> ToolResult {
        await act(arguments, caption: "Alternar") { element in
            element.alias.map { .toggle(alias: $0) }
        }
    }

    /// An action on `@reading:alias`, checked against that reading like `tap`.
    private func act(_ arguments: [String: Any], caption: String, _ build: @escaping (UIElement) -> DeviceAction?) async -> ToolResult {
        guard let (reading, alias) = Self.alias(arguments["alias"]) else {
            return .invalid("`alias` va completo, como aparece en la lectura: `12:5` es el elemento 5 de la lectura 12.")
        }
        if let failure = await ensureConnected() { return failure }
        await inspector.act(onAlias: alias, seenIn: reading, build)
        return finished("\(caption) en @\(reading):\(alias)")
    }

    private func typeText(_ arguments: [String: Any]) async -> ToolResult {
        guard let text = arguments["text"] as? String, !text.isEmpty else { return .invalid("Falta `text`.") }
        return await perform(.inputText(text))
    }

    private func eraseText(_ arguments: [String: Any]) async -> ToolResult {
        guard let count = Self.int(arguments["count"]), count > 0 else { return .invalid("`count` tiene que ser mayor que 0.") }
        return await perform(.eraseText(characters: count))
    }

    private func scroll(_ arguments: [String: Any]) async -> ToolResult {
        guard let direction = (arguments["direction"] as? String).flatMap(ScrollDirection.init(rawValue:)) else {
            return .invalid("`direction` es `down` o `up`.")
        }
        if let failure = await ensureConnected() { return failure }
        return await perform(.scroll(direction, screen: inspector.screenSize))
    }

    private func swipe(_ arguments: [String: Any]) async -> ToolResult {
        let values = ["from_x", "from_y", "to_x", "to_y"].compactMap { Self.double(arguments[$0]) }
        guard values.count == 4 else { return .invalid("Faltan coordenadas.") }
        return await perform(.swipe(from: CGPoint(x: values[0], y: values[1]), to: CGPoint(x: values[2], y: values[3])))
    }

    private func pressButton(_ arguments: [String: Any]) async -> ToolResult {
        guard let button = arguments["button"] as? String else { return .invalid("Falta `button`.") }
        return await perform(.pressButton(button))
    }

    /// `ScreenInspector.perform` espera a que la pantalla se asiente y la relee.
    private func perform(_ action: DeviceAction) async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        await inspector.perform(action)
        return finished(action.caption)
    }

    /// A failure worth retrying comes with the current screen, so the retry needs no extra read.
    /// The delivery line says what was tried and what was read back, so a press that did
    /// nothing is not mistaken for one that worked.
    private func finished(_ caption: String) -> ToolResult {
        if let failure = inspector.failure {
            return .error(failure, appending: failure.retrySafe ? outline() : nil)
        }
        let steps = inspector.lastDelivery
        guard !steps.isEmpty else { return .text("\(caption) → listo.\n\n\(outline())") }
        // Text only: Claude Code shows `structuredContent` instead of the text when both come,
        // and the reply would lose the screen.
        return .text("\(caption) → listo.\nEntrega: \(steps.map(\.caption).joined(separator: " → "))\n\n\(outline())")
    }

    private func screenshot() async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        guard let driver = inspector.driver else { return .error(ToolError.notConnected("No hay dispositivo conectado.")) }
        let png: Data
        do {
            png = try await driver.screenshot()
        } catch {
            return .error(fingertipError(error))
        }

        // The folder chosen in the Fingertip app, read per call so a change applies without reconnecting.
        let directory = FingertipSettings.load().effectiveScreenshotsDirectory
        let file = Self.screenshotFile(in: directory)
        let saved: String
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: file, options: .withoutOverwriting)
            saved = "PNG completo: \(file.path)"
        } catch {
            saved = "No pude guardar el PNG en \(directory.path): \(error.localizedDescription)"
        }

        guard let jpeg = Self.reduced(png, maxSide: Self.inlineImageSide) else {
            return .text("No pude reducir la captura. \(saved)")
        }
        return ToolResult(content: [
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": saved]
        ])
    }

    // MARK: - Recording

    private func startRecording() async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        guard let driver = inspector.driver else { return .error(ToolError.notConnected("No hay dispositivo conectado.")) }
        // The folder chosen in the Fingertip app, read per call like the screenshots one.
        let directory = FingertipSettings.load().effectiveRecordingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = Self.recordingFile(in: directory)
            try await driver.startRecording(to: file)
            return .text("Grabando → \(file.path)\nTermínala con `stop_recording`.")
        } catch {
            return .error(fingertipError(error))
        }
    }

    private func stopRecording() async -> ToolResult {
        // No `ensureConnected`: stopping must not connect to anything.
        guard let driver = inspector.driver else { return .error(RecordingError.notRecording) }
        do {
            let file = try await driver.stopRecording()
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            return .text("Grabación guardada: \(file.path) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        } catch {
            return .error(fingertipError(error))
        }
    }

    /// `fingertip-2026-11-01-12.30.05.123.mov`, with the same collision rule as the screenshots.
    private static func recordingFile(in directory: URL) -> URL {
        let stem = "fingertip-\(screenshotFormatter.string(from: .now))"
        var file = directory.appending(path: "\(stem).mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "\(stem)-\(suffix).mov")
            suffix += 1
        }
        return file
    }

    private static let screenshotFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss.SSS"
        return formatter
    }()

    /// `fingertip-2026-11-01-12.30.05.123.png`: sorts by time and reads well in a user's folder.
    /// The same name can come back (the hour repeated when clocks go back), so a taken one gets
    /// a `-2`, `-3`… instead of overwriting an earlier capture.
    private static func screenshotFile(in directory: URL) -> URL {
        let stem = "fingertip-\(screenshotFormatter.string(from: .now))"
        var file = directory.appending(path: "\(stem).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "\(stem)-\(suffix).png")
            suffix += 1
        }
        return file
    }

    private static func reduced(_ png: Data, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Ciclo de vida

    private func relaunchApp(_ arguments: [String: Any]) async -> ToolResult {
        guard let bundleID = arguments["bundle_id"] as? String, !bundleID.isEmpty else { return .invalid("Falta `bundle_id`.") }
        if Self.isBlocked(bundleID) { return Self.blockedError(bundleID) }
        if let failure = await ensureConnected() { return failure }
        guard await inspector.relaunch(bundleID) else {
            return .error(inspector.failure ?? UnexpectedError(message: "No pude relanzar \(bundleID)."))
        }
        return .text("\(bundleID) relanzada.\n\n\(outline())")
    }

    private func terminateApp(_ arguments: [String: Any]) async -> ToolResult {
        guard let bundleID = arguments["bundle_id"] as? String, !bundleID.isEmpty else { return .invalid("Falta `bundle_id`.") }
        if Self.isBlocked(bundleID) { return Self.blockedError(bundleID) }
        if let failure = await ensureConnected() { return failure }
        do {
            try await inspector.driver?.terminate(bundleID: bundleID)
        } catch {
            return .error(fingertipError(error))
        }
        return .text("\(bundleID) cerrada.")
    }

    // MARK: - Jev

    private func runInstruction(_ arguments: [String: Any]) async -> ToolResult {
        guard let instruction = arguments["instruction"] as? String, !instruction.isEmpty else {
            return .invalid("Falta `instruction`.")
        }
        let bundleID = arguments["bundle_id"] as? String ?? ""
        if Self.isBlocked(bundleID) { return Self.blockedError(bundleID) }
        if let failure = await ensureConnected() { return failure }
        agent.instruction = instruction
        agent.bundleID = bundleID
        guard agent.canStep else { return .error(inspector.failure ?? ToolError.notConnected("El dispositivo no está listo.")) }
        await agent.run()

        let result = switch agent.outcome {
        case .goalReached: "goal_reached"
        case .needsUser: "needs_user"
        case .acted, .screenChanged, .none: agent.failure == nil ? "stopped" : "error"
        }
        var lines = ["Resultado: \(result)"]
        if let failure = agent.failure {
            lines.append("Error \(failure.code) · retry_safe: \(failure.retrySafe)\n\(failure.errorDescription ?? "")")
        }
        lines.append("Pasos:")
        lines += agent.history.isEmpty ? ["  (ninguno)"] : agent.history.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        if let decision = agent.decision {
            lines.append(String(format: "Última decisión: confianza %.2f, instrucción cumplida %.2f", decision.confidence, decision.goalReached))
            if agent.heldForRisk, let risk = decision.risk {
                lines.append(String(format: "Frené: el paso parece destructivo (riesgo %.2f) y la confianza %.2f no llega a %.2f. Confirmá vos antes de tocarlo.", risk, decision.confidence, JevAgent.destructiveConfidence))
            }
            if case .needsUser = agent.outcome {
                lines.append("Opciones que barajó Jev:")
                lines += decision.ranked.prefix(5).map { option in
                    let caption = option.element.map { "@\($0.alias.map(String.init) ?? "-") \($0.type) \"\($0.caption)\"" } ?? "(ninguno / scroll)"
                    return String(format: "  %.2f  %@", option.probability, caption)
                }
            }
        }
        if let path = agent.logPath { lines.append("Log: \(path)") }
        lines += ["", outline()]
        let text = lines.joined(separator: "\n")
        // Structured content only on an error: on a success Claude Code shows it instead of the
        // text, and the steps and the screen would be lost.
        guard result == "error" else {
            var reply = ToolResult.text(text)
            reply.outcome = result
            return reply
        }
        var structured: [String: Any] = ["result": result]
        if let failure = agent.failure {
            structured["error"] = ["code": failure.code, "retry_safe": failure.retrySafe, "message": failure.errorDescription ?? ""]
        }
        return ToolResult(content: [["type": "text", "text": text]], isError: true, structured: structured, outcome: result)
    }

    // MARK: - Utilidades

    private static func describe(_ target: Target) -> String {
        switch target {
        case .simulator(let udid): "simulador \(udid)"
        case .mac(let app): "\(app.name) (\(app.bundleID), \(app.bundleURL.path))"
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// `12:5` or `@12:5`. A bare `5` is rejected: without the reading it cannot be checked.
    private static func alias(_ value: Any?) -> (reading: Int, alias: Int)? {
        guard let text = value as? String else { return nil }
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).split(separator: ":")
        guard parts.count == 2, let reading = Int(parts[0]), let alias = Int(parts[1]) else { return nil }
        return (reading, alias)
    }

    /// JSONSerialization da NSNumber: un entero puede llegar como 3 o 3.0.
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
}
