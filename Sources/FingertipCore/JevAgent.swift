//
//  JevAgent.swift
//  FingertipCore
//
//  Fase 4: un paso de decisión. Lee la pantalla, le pregunta a Jev qué tocar
//  y ejecuta el tap. Si la confianza es baja, no actúa: muestra las opciones.
//  Fase 5: repite ese paso hasta que la instrucción se cumpla o se llegue al
//  tope, pasándole a Jev el historial de lo que ya se hizo. Si el elemento es un
//  campo de texto, el paso es tocar y escribir.
//

import Foundation
import Observation

public nonisolated enum JevAgentError: FingertipError {
    case nothingActionable
    case maxSteps(Int)
    case appCrashed(String)

    public var code: String {
        switch self {
        case .nothingActionable: "nothing_actionable"
        case .maxSteps: "max_steps"
        case .appCrashed: "app_crashed"
        }
    }

    /// A screen that is still loading may have something to act on a moment later.
    public var retrySafe: Bool {
        if case .nothingActionable = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .nothingActionable: "No hay elementos tocables en la pantalla."
        case .maxSteps(let steps): "Frené después de \(steps) pasos sin cumplir la instrucción."
        case .appCrashed(let bundleID): "\(bundleID) dejó de correr a mitad de la corrida (¿crash?)."
        }
    }
}

@Observable
public final class JevAgent {
    /// Debajo de esto no se actúa: se le pasa la decisión al usuario.
    public static let minimumConfidence = 0.6
    /// A tap rated destructive needs this much confidence in its target.
    public static let destructiveConfidence = 0.9
    /// Risk from which a tap counts as destructive.
    public static let destructiveRisk = 0.5
    /// Probabilidad a partir de la cual se considera cumplida la instrucción.
    private static let goalThreshold = 0.5
    /// Tope duro de pasos: sin esto, un flujo que no avanza queda dando vueltas.
    public static let maxSteps = 10
    /// Above this many actionable elements Jev chooses a region first, then an element in it.
    public static let maxCandidates = 60
    /// Cuánto esperar a que la app relanzada quede en primer plano (tarda ~4 s).
    private static let launchTimeout = Duration.seconds(15)
    /// Pausa del loop de capturas. La captura en sí tarda ~0.5 s.
    private static let watchInterval = Duration.milliseconds(300)

    public enum Outcome {
        case acted(String)
        case goalReached
        case needsUser
        /// The screen changed between the read and the tap; the next step reads it again.
        case screenChanged
    }

    public var instruction = ""
    /// App bajo prueba. Vacío: la corrida arranca donde esté el dispositivo, como antes.
    public var bundleID = ""
    public private(set) var isThinking = false
    public private(set) var isRunning = false
    /// Pasos ya ejecutados en esta corrida: se muestran y se le pasan a Jev.
    public private(set) var history: [String] = []
    /// Archivo JSONL de la corrida actual, para poder ir a mirarlo.
    public private(set) var logPath: String?
    /// Where the next run is logged; nil is the settings' runs folder. A test points it at its `jev/`.
    public var runsDirectory: URL?
    public private(set) var decision: JevDecision?
    public private(set) var outcome: Outcome?
    public private(set) var failure: (any FingertipError)?
    public var errorMessage: String? { failure?.errorDescription }

    private let inspector: ScreenInspector
    private let jev = JevClient()
    private var log: RunLog?
    private var stepIndex = 0
    /// The reading `decision` was made on: its element is tapped only if that still holds.
    private var decisionReading = 0
    /// Region Jev chose to look inside; later steps only offer its elements.
    public private(set) var drilledRegion: String?
    /// Se setea cuando la app bajo prueba desaparece a mitad de corrida.
    private var crashed = false
    private var watchTask: Task<Void, Never>?

    public init(inspector: ScreenInspector) {
        self.inspector = inspector
    }

    /// El bundle id como lo usa el resto de la clase. Vacío: no hay app bajo prueba.
    private var appUnderTest: String {
        bundleID.trimmingCharacters(in: .whitespaces)
    }

    /// The step stopped because its tap was rated destructive, not because the choice was unclear.
    public var heldForRisk: Bool {
        guard case .needsUser = outcome, let risk = decision?.risk else { return false }
        return risk >= Self.destructiveRisk
    }

    public var canStep: Bool {
        !instruction.trimmingCharacters(in: .whitespaces).isEmpty
            && inspector.connectionState == .ready
            && !isThinking
            && !isRunning
    }

    /// Encadena pasos hasta que Jev diga que la instrucción está cumplida, que
    /// necesita al usuario, que algo falló, o hasta el tope de pasos.
    public func run() async {
        guard canStep else { return }
        isRunning = true
        defer { isRunning = false }
        history = []
        stepIndex = 0
        failure = nil
        outcome = nil
        drilledRegion = nil

        let log = RunLog(directory: runsDirectory)
        self.log = log
        logPath = log.path
        watchTask = watchScreen()
        defer {
            watchTask?.cancel()
            watchTask = nil
        }

        crashed = false
        let bundleID = appUnderTest
        let relaunched = bundleID.isEmpty ? false : await relaunch(bundleID)
        await log.append(["event": "run", "instruction": JevClient.redactingTextCandidates(in: instruction), "bundle_id": bundleID, "relaunched": relaunched])
        if !bundleID.isEmpty && !relaunched {
            await log.append(["event": "end", "steps": 0, "reason": "error", "error": errorMessage ?? ""])
            return
        }

        for _ in 0..<Self.maxSteps {
            await step()
            let continues = switch outcome {
            case .acted, .screenChanged: failure == nil
            default: false
            }
            guard continues else {
                await log.append(["event": "end", "steps": stepIndex, "reason": endReason])
                return
            }
        }
        failure = JevAgentError.maxSteps(Self.maxSteps)
        await log.append(["event": "end", "steps": stepIndex, "reason": "max_steps"])
    }

    /// Toda corrida arranca de la pantalla inicial. Sin esperar a que la app
    /// esté lista, el primer paso lee el springboard. Va acá y no en `step()`,
    /// que se invoca suelto.
    private func relaunch(_ bundleID: String) async -> Bool {
        let ready = await inspector.relaunch(bundleID, timeout: Self.launchTimeout)
        if !ready { failure = inspector.failure }
        return ready
    }

    private var endReason: String {
        if crashed { return "app_crashed" }
        if failure != nil { return "error" }
        switch outcome {
        case .goalReached: return "goal_reached"
        case .needsUser: return "needs_user"
        case .screenChanged: return "screen_changed"
        case .acted, .none: return "stopped"
        }
    }

    public func step() async {
        isThinking = true
        defer { isThinking = false }
        failure = nil
        outcome = nil
        stepIndex += 1

        await inspector.readScreen()
        decisionReading = inspector.reading

        // sim-use compara el set de procesos entre llamadas: si la app se murió,
        // `ui` devuelve el springboard sin quejarse y Jev decidiría sobre una
        // pantalla que no es la app. La corrida corta acá, con el motivo.
        let bundleID = appUnderTest
        if !bundleID.isEmpty && inspector.vanishedApps.contains(bundleID) {
            crashed = true
            failure = JevAgentError.appCrashed(bundleID)
            await log?.append([
                "event": "step", "step": stepIndex,
                "outcome": "app_crashed", "bundle_id": bundleID,
                "error": errorMessage ?? ""
            ])
            return
        }

        let actionable = inspector.elements.filter(\.isActionable)
        guard !actionable.isEmpty else {
            failure = JevAgentError.nothingActionable
            await log?.append(["event": "step", "step": stepIndex, "error": errorMessage ?? ""])
            return
        }

        // A region that emptied or went away gives the whole window back.
        var candidates = actionable
        if let region = drilledRegion {
            let inside = actionable.filter { $0.region == region }
            if inside.isEmpty { drilledRegion = nil } else { candidates = inside }
        }
        var regions: [RegionSummary] = []
        if drilledRegion == nil && candidates.count > Self.maxCandidates {
            regions = Self.summarize(candidates)
            candidates = []
        }

        await status("Paso \(stepIndex) · Jev decidiendo…", .working)
        let decision: JevDecision
        do {
            decision = try await jev.decide(
                instruction: instruction, history: history, candidates: candidates,
                regions: regions, canWiden: drilledRegion != nil
            )
        } catch {
            failure = fingertipError(error)
            await log?.append(["event": "step", "step": stepIndex, "error": errorMessage ?? ""])
            return
        }
        self.decision = decision

        if decision.goalReached >= Self.goalThreshold {
            outcome = .goalReached
        } else if decision.widen, decision.confidence >= Self.minimumConfidence {
            look(at: nil)
        } else if let region = decision.region, decision.confidence >= Self.minimumConfidence {
            look(at: region)
        } else if let scroll = decision.scroll, decision.confidence >= Self.minimumConfidence {
            await self.scroll(scroll)
        } else if let element = decision.element, decision.confidence >= Self.minimumConfidence {
            if await clearsRiskBar(element) {
                await act(on: element, typing: decision.textToType)
            } else {
                outcome = .needsUser
            }
        } else {
            outcome = .needsUser
        }
        await reportStatus(self.decision ?? decision)
        await logStep(self.decision ?? decision, candidates: candidates.count + regions.count)
        if case .acted = outcome { await captureScreen(trigger: "action") }
    }

    private func status(_ text: String, _ state: OverlayStatus) async {
        await ActivityBeacon.shared.send(.status(text: text, state: state))
    }

    /// The step's outcome for the Fingertip app's toast.
    private func reportStatus(_ decision: JevDecision) async {
        let step = "Paso \(stepIndex)"
        let confidence = String(format: "%.2f", decision.confidence)
        if failure != nil { return }
        switch outcome {
        case .goalReached:
            await status("Jev: instrucción cumplida", .goal)
        case .needsUser:
            if heldForRisk, let risk = decision.risk {
                await status(String(format: "\(step) · frené: parece destructivo (riesgo %.2f)", risk), .held)
            } else {
                await status("\(step) · Jev no está seguro (\(confidence)): elegí vos", .held)
            }
        case .acted(let caption):
            await status("\(step) · \(caption) (\(confidence))", .working)
        case .screenChanged:
            await status("\(step) · la pantalla cambió, vuelvo a mirar", .working)
        case nil:
            break
        }
    }

    /// Looking is a step of its own: nothing on screen changes, only what the next step offers.
    private func look(at region: String?) {
        drilledRegion = region
        let caption = region.map { "Miré dentro de «\($0)»" } ?? "Volví a mirar la ventana entera"
        history.append(caption)
        outcome = .acted(caption)
    }

    /// Regions in screen order, each with a few captions so Jev can tell them apart.
    private static func summarize(_ elements: [UIElement]) -> [RegionSummary] {
        var order: [String] = []
        var members: [String: [UIElement]] = [:]
        for element in elements {
            if members[element.region] == nil { order.append(element.region) }
            members[element.region, default: []].append(element)
        }
        return order.map { name in
            let inside = members[name] ?? []
            let sample = inside.prefix(5).map { String($0.caption.prefix(30)) }
            return RegionSummary(name: name, count: inside.count, sample: sample)
        }
    }

    /// A confidence that already meets the destructive bar needs no rating. Below it the
    /// tap is rated, and a rating that fails counts as destructive.
    private func clearsRiskBar(_ element: UIElement) async -> Bool {
        guard var decision, decision.confidence < Self.destructiveConfidence else { return true }
        let risk: Double
        do {
            risk = try await jev.risk(of: element, instruction: instruction, history: history)
        } catch {
            risk = 1
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await log?.append(["event": "risk_error", "step": stepIndex, "error": reason])
        }
        decision.risk = risk
        self.decision = decision
        return risk < Self.destructiveRisk
    }

    /// La pantalla también cambia sola entre acciones (una carga que termina,
    /// el relanzamiento): se captura en loop y solo queda lo que cambió. Va con
    /// screenshots y no con `ui`, que reescribiría los alias `@N` entre la
    /// lectura del paso y su tap.
    private func watchScreen() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await captureScreen(trigger: "change")
                try? await Task.sleep(for: Self.watchInterval)
            }
        }
    }

    /// Las capturas de una acción quedan en el log aunque la imagen ya exista,
    /// porque "después de tocar, la pantalla quedó así" también es un resultado;
    /// las del loop, solo si es una imagen que la corrida no vio todavía.
    private func captureScreen(trigger: String) async {
        guard let log, let driver = inspector.driver,
              let png = try? await driver.screenshot(),
              !Task.isCancelled,
              let shot = await log.saveScreenshot(png),
              shot.isNew || trigger == "action"
        else { return }
        await log.append(["event": "screenshot", "trigger": trigger, "step": stepIndex, "file": shot.name, "new": shot.isNew])
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// Una línea JSON por paso: qué vio, qué eligió, qué hizo y cuánto costó.
    private func logStep(_ decision: JevDecision, candidates: Int) async {
        var entry: [String: Any] = [
            "event": "step",
            "step": stepIndex,
            "candidates": candidates,
            "choice": decision.choiceKey ?? "",
            "caption": decision.element?.caption ?? decision.scroll?.caption ?? decision.region ?? (decision.widen ? "ver todo" : ""),
            "confidence": Self.rounded(decision.confidence),
            "goal_reached": Self.rounded(decision.goalReached),
            "outcome": endReason,
            "ms": decision.elapsedMs,
            "input_tokens": decision.inputTokens,
            "output_tokens": decision.outputTokens
        ]
        if case .acted(let caption) = outcome { entry["outcome"] = "acted"; entry["action"] = caption }
        // The text may be a password from the instruction; the log stays on disk, so only its length.
        if let text = decision.textToType { entry["text_length"] = text.count }
        if let risk = decision.risk { entry["risk"] = Self.rounded(risk) }
        if let failure {
            entry["error"] = failure.errorDescription ?? ""
            entry["error_code"] = failure.code
        }
        await log?.append(entry)
    }

    /// Lo que hace falta no está en pantalla: se desliza y el próximo paso lee
    /// la pantalla nueva. Queda en el historial, así que si Jev sigue eligiendo
    /// scroll sin que aparezca nada, lo ve; el tope de pasos corta igual.
    private func scroll(_ direction: ScrollDirection) async {
        await inspector.perform(.scroll(direction, screen: inspector.screenSize))
        guard inspector.failure == nil else {
            failure = inspector.failure
            return
        }
        history.append(direction.caption)
        outcome = .acted(direction.caption)
    }

    /// Tocar y, si el elemento acepta texto y Jev eligió qué escribir, escribirlo.
    private func act(on element: UIElement, typing text: String?) async {
        await inspector.tap(element, seenIn: decisionReading)
        if let changed = inspector.failure as? InspectorError, case .screenChanged = changed {
            outcome = .screenChanged
            return
        }
        guard inspector.failure == nil else {
            failure = inspector.failure
            return
        }
        history.append("Toqué \"\(element.caption)\"")
        outcome = .acted(element.caption)

        guard element.acceptsText, let text else { return }
        await inspector.perform(.inputText(text))
        guard inspector.failure == nil else {
            failure = inspector.failure
            return
        }
        history.append("Escribí \"\(text)\"")
        // The outcome reaches the toast on screen; the text may be a password, so only its length.
        outcome = .acted("\(element.caption) → \(text.count) caracteres")
    }
}
