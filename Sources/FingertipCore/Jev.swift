//
//  Jev.swift
//  FingertipCore
//
//  Cliente de TypeSafe System One. No hay SDK de Swift: URLSession contra
//  POST /v1/systemone. Jev no genera texto, responde preguntas tipadas: el
//  código Swift enumera los elementos candidatos y Jev solo elige entre ellos.
//

import Foundation

nonisolated enum JevError: FingertipError {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case badResponse(String)
    case network(String)

    var code: String {
        switch self {
        case .missingAPIKey: "jev_missing_api_key"
        case .httpError: "jev_http_error"
        case .badResponse: "jev_bad_response"
        case .network: "jev_network"
        }
    }

    /// A Jev request only reads, so repeating it is harmless; a rejected key or request is not worth repeating.
    var retrySafe: Bool {
        switch self {
        case .missingAPIKey: false
        case .httpError(let status, _): status == 429 || status >= 500
        case .badResponse, .network: true
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "TYPESAFE_API_KEY is missing: Jev is only needed for `run_instruction`; the other tools work without it. Enter it in Fingertip → Settings → Jev and register the MCP again from Settings → General (then `/mcp` in Claude Code). Registering by hand: `claude mcp add fingertip -e TYPESAFE_API_KEY=… -- <path>/fingertip-mcp`."
        case .httpError(let status, let body):
            "TypeSafe returned \(status): \(body)"
        case .badResponse(let detail):
            "Unexpected response from TypeSafe: \(detail)"
        case .network(let detail):
            "Couldn't reach TypeSafe: \(detail)"
        }
    }
}

/// A region offered to Jev instead of its elements when the screen is too dense to list.
public nonisolated struct RegionSummary: Sendable {
    public var name: String
    public var count: Int
    /// A few captions, so Jev can tell what the region holds.
    public var sample: [String]
}

/// Lo que Jev respondió para un paso.
public nonisolated struct JevDecision: Sendable {
    /// Elemento elegido; `nil` si eligió "ninguno".
    public var element: UIElement?
    /// Confianza del Choice (0-1).
    public var confidence: Double
    /// Probabilidad de que la instrucción ya esté cumplida.
    public var goalReached: Double
    /// Distribución completa, ordenada, para mostrarle las opciones al usuario.
    public var ranked: [(element: UIElement?, probability: Double)]
    /// Texto a escribir si el elemento elegido es un campo; `nil` si no hay que escribir.
    public var textToType: String?
    /// Dirección elegida cuando Jev decide que lo que hace falta no está visible.
    public var scroll: ScrollDirection?
    /// La opción cruda que eligió Jev (`e27`, `ninguno`, `scroll_abajo`), para el log.
    public var choiceKey: String?
    /// Region chosen to look inside, on a screen too dense to list whole.
    public var region: String?
    /// Jev chose to go back from a region to the whole window.
    public var widen = false
    public var elapsedMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    /// Probability that tapping `element` is hard to undo; `nil` when the step was not rated.
    public var risk: Double? = nil
}

actor JevClient {
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let model = "jev-latest"
    /// Clave de escape del Choice: Jev puede decir que ninguno sirve.
    private static let noneOption = "ninguno"
    private static let widenOption = "ver_todo"

    /// Los candidatos son solo lo que está a la vista, así que sin estas dos
    /// opciones un objetivo que quedó fuera de pantalla deja el loop trabado.
    /// Van en el mismo Choice y no en una pregunta aparte: es la misma decisión.
    private static let scrollOptions: [String: ScrollDirection] = [
        "scroll_abajo": .down,
        "scroll_arriba": .up
    ]

    /// Jev no genera texto: lo que se escribe sale de la propia instrucción.
    /// Mails, lo que va entre comillas y los tokens con dígitos (claves, códigos).
    static func textCandidates(in instruction: String) -> [String] {
        let patterns = [
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #""([^"]{1,80})""#,
            #"\S*\d\S*"#
        ]
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let whole = NSRange(instruction.startIndex..., in: instruction)
            for match in regex.matches(in: instruction, range: whole) {
                let group = match.numberOfRanges > 1 ? 1 : 0
                guard let range = Range(match.range(at: group), in: instruction) else { continue }
                let text = String(instruction[range]).trimmingCharacters(in: .punctuationCharacters)
                if !text.isEmpty, !found.contains(text) { found.append(text) }
            }
        }
        return found
    }

    /// The instruction with every text Jev could type replaced, for the run log on disk:
    /// those texts are the ones that may be a password. Longest first, so a candidate
    /// inside another one doesn't break it.
    static func redactingTextCandidates(in instruction: String) -> String {
        textCandidates(in: instruction)
            .sorted { $0.count > $1.count }
            .reduce(instruction) { $0.replacingOccurrences(of: $1, with: "[text]") }
    }

    /// Una sola request con las preguntas del paso: qué tocar, si ya terminamos y,
    /// cuando la instrucción trae algún texto, cuál escribir.
    /// With `regions`, the screen is too dense to list: Jev picks a region to look
    /// inside instead of an element. With `canWiden`, the candidates are one region
    /// and Jev may go back to the whole window.
    func decide(
        instruction: String, history: [String], candidates: [UIElement],
        regions: [RegionSummary] = [], canWiden: Bool = false
    ) async throws -> JevDecision {
        var options = Dictionary(
            uniqueKeysWithValues: candidates.enumerated().map { index, element in
                ("e\(index)", "\(element.type): \(element.caption)")
            }
        ).merging([
            Self.noneOption: "Ninguno de los elementos de la pantalla sirve para este paso.",
            "scroll_abajo": "Lo que hace falta no está visible: hay que deslizar para ver el contenido que sigue más abajo.",
            "scroll_arriba": "Lo que hace falta no está visible: hay que deslizar para volver al contenido que quedó más arriba."
        ]) { a, _ in a }
        for (index, region) in regions.enumerated() {
            options["r\(index)"] = "Mirar dentro de la región «\(region.name)» (\(region.count) elementos, p. ej. \(region.sample.map { "«\($0)»" }.joined(separator: ", ")))."
        }
        if canWiden {
            options[Self.widenOption] = "Lo que hace falta no está en esta región: volver a mirar la ventana entera."
        }

        let texts = Self.textCandidates(in: instruction)
        var questions: [String: Any] = [
            "next_element": [
                "type": "choice",
                "instructions": "¿Qué elemento de la pantalla hay que tocar para avanzar con la instrucción del usuario? La lista es solo lo que está a la vista: si lo que hace falta no aparece, elegí deslizar en vez de tocar algo que no corresponde.",
                "criteria": options
            ],
            "goal_reached": [
                "type": "noul",
                "instructions": "¿La instrucción del usuario ya está cumplida en la pantalla actual?",
                "criteria": [
                    "true": "La pantalla actual muestra que la instrucción ya se completó.",
                    "false": "Todavía falta al menos una acción."
                ]
            ]
        ]

        // Solo tiene sentido preguntar qué escribir si la instrucción trae algún texto.
        if !texts.isEmpty {
            var textOptions = Dictionary(
                uniqueKeysWithValues: texts.enumerated().map { ("t\($0.offset)", $0.element) }
            )
            textOptions[Self.noneOption] = "En este paso no hay que escribir nada."
            questions["text_to_type"] = [
                "type": "choice",
                "instructions": "Si el elemento elegido es un campo de texto, ¿cuál de estos textos de la instrucción hay que escribir ahí? Si no hay que escribir nada, elegí \"ninguno\".",
                "criteria": textOptions
            ]
        }

        let body: [String: Any] = [
            "model": Self.model,
            "state": state(instruction: instruction, history: history, candidates: candidates, regions: regions),
            "questions": questions
        ]

        let started = ContinuousClock.now
        let response = try await post(body)
        let elapsed = started.duration(to: .now).components
        let elapsedMs = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let answers = response.answers
        guard let choice = answers["next_element"], let goal = answers["goal_reached"]?.noul else {
            throw JevError.badResponse("missing next_element or goal_reached")
        }

        /// Solo las claves `eN` mapean a un elemento; `ninguno` y los scroll no.
        func element(for key: String) -> UIElement? {
            guard key.hasPrefix("e"), let index = Int(key.dropFirst()), candidates.indices.contains(index) else {
                return nil
            }
            return candidates[index]
        }

        let ranked = (choice.probabilities ?? [:])
            .sorted { $0.value > $1.value }
            .map { (element(for: $0.key), $0.value) }

        let textChoice = answers["text_to_type"]?.choice
        let textToType = textChoice
            .flatMap { Int($0.dropFirst()) }
            .flatMap { texts.indices.contains($0) ? texts[$0] : nil }

        return JevDecision(
            element: choice.choice.flatMap(element(for:)),
            confidence: choice.confidence ?? 0,
            goalReached: goal,
            ranked: ranked,
            textToType: textToType,
            scroll: choice.choice.flatMap { Self.scrollOptions[$0] },
            choiceKey: choice.choice,
            region: choice.choice.flatMap { key in
                guard key.hasPrefix("r"), let index = Int(key.dropFirst()), regions.indices.contains(index) else { return nil }
                return regions[index].name
            },
            widen: choice.choice == Self.widenOption,
            elapsedMs: elapsedMs,
            inputTokens: response.usage?.inputTokens ?? 0,
            outputTokens: response.usage?.outputTokens ?? 0
        )
    }

    /// Probability that tapping `element` is hard to undo. A separate request because
    /// the element is only known once `decide` has answered.
    func risk(of element: UIElement, instruction: String, history: [String]) async throws -> Double {
        let done = history.isEmpty
            ? "Todavía no se ejecutó ningún paso."
            : history.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": Self.model,
            "state": """
            Instrucción del usuario: \(instruction)

            Pasos ya ejecutados:
            \(done)

            Elemento que se está por tocar: [\(element.type)] \(element.caption)
            """,
            "questions": [
                "destructive": [
                    "type": "noul",
                    "instructions": "¿Tocar este elemento hace algo difícil o imposible de deshacer, como borrar, descartar cambios sin guardar, enviar, comprar, cerrar sesión o restablecer?",
                    "criteria": [
                        "true": "Tocarlo borra, descarta, envía, paga, cierra sesión o cambia algo que no se recupera con deshacer o volver atrás.",
                        "false": "Tocarlo solo navega, abre, selecciona, enfoca o cambia algo que se puede revertir."
                    ]
                ]
            ]
        ]
        guard let risk = try await post(body).answers["destructive"]?.noul else {
            throw JevError.badResponse("missing destructive")
        }
        return risk
    }

    /// El `state` es lo que Jev ve: la instrucción, lo que ya se hizo y la pantalla.
    private func state(instruction: String, history: [String], candidates: [UIElement], regions: [RegionSummary]) -> String {
        let elements = candidates.enumerated()
            .map { "e\($0.offset): [\($0.element.type)] \($0.element.caption)" }
        let summaries = regions.enumerated()
            .map { "r\($0.offset): región «\($0.element.name)», \($0.element.count) elementos" }
        let list = (elements + summaries).joined(separator: "\n")
        let header = regions.isEmpty
            ? "Elementos tocables visibles en la pantalla actual (puede haber más\ncontenido fuera de la vista, arriba o abajo):"
            : "La pantalla tiene demasiados elementos para listarlos uno por uno. Estas son sus regiones: para tocar algo, primero hay que mirar dentro de una."

        let done = history.isEmpty
            ? "Todavía no se ejecutó ningún paso."
            : history.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        Instrucción del usuario: \(instruction)

        Pasos ya ejecutados:
        \(done)

        \(header)
        \(list)
        """
    }

    // MARK: - HTTP

    /// The key comes from the server's environment, set when it is registered; never from the repo.
    private static func apiKey() throws -> String {
        let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw JevError.missingAPIKey }
        return key
    }

    private func post(_ body: [String: Any]) async throws -> JevResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try Self.apiKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw JevError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw JevError.httpError(status: http.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(JevResponse.self, from: data)
        } catch {
            throw JevError.badResponse(String(decoding: data.prefix(400), as: UTF8.self))
        }
    }
}

nonisolated struct JevResponse: Decodable, Sendable {
    var answers: [String: Answer]
    var usage: Usage?

    struct Usage: Decodable, Sendable {
        var inputTokens: Int
        var outputTokens: Int

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct Answer: Decodable, Sendable {
        var type: String
        var choice: String?
        var noul: Double?
        var probabilities: [String: Double]?
        var confidence: Double?
    }
}
