//
//  ScreenInspector.swift
//  FingertipCore
//
//  Estado de la Fase 2: conectarse al dispositivo y leer la pantalla actual.
//  No hay driver que levantar: conectar es verificar que el driver tiene lo
//  que necesita (el binario de sim-use, el permiso de Accesibilidad) y hacer
//  la primera lectura, que en el simulador deja el daemon caliente (~1.5 s la
//  primera vez, ~0.5 s después).
//

import CoreGraphics
import Foundation
import Observation

@Observable
public final class ScreenInspector {
    public enum ConnectionState: Equatable {
        case disconnected, connecting, ready
    }

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var elements: [UIElement] = []
    public private(set) var screenSize: CGSize = .zero
    public private(set) var appLabel: String?
    public private(set) var appPackage: String?
    public private(set) var vanishedApps: [String] = []
    public private(set) var isReading = false
    public private(set) var isActing = false
    public private(set) var lastAction: String?
    /// What each strategy of the last action did, when the driver reports it.
    public private(set) var lastDelivery: [DeliveryStep] = []
    public private(set) var failure: (any FingertipError)?
    public var errorMessage: String? { failure?.errorDescription }

    /// Number of the current reading. It only moves when the element list changes,
    /// so reading an unchanged screen twice keeps its aliases valid.
    public private(set) var reading = 0
    /// Recent readings, so an alias seen in one of them can be checked against the screen now.
    private var past: [Int: [UIElement]] = [:]
    private static let keptReadings = 20
    /// Where the current reading's bounds sit on this Mac's screen; `nil` on the simulator.
    private var screenOrigin: CGPoint?

    /// El driver del dispositivo conectado; `nil` si no hay ninguno.
    public private(set) var driver: (any ScreenDriver)?

    public init() {}

    public var regions: [String] {
        var seen: [String] = []
        for element in elements where !seen.contains(element.region) {
            seen.append(element.region)
        }
        return seen
    }

    public func elements(in region: String) -> [UIElement] {
        elements.filter { $0.region == region }
    }

    public func connect(_ target: Target) async {
        connectionState = .connecting
        failure = nil
        // The previous device's origin must not place a pointer for this one.
        screenOrigin = nil
        let driver = target.makeDriver()

        do {
            try await driver.preflight()
        } catch {
            connectionState = .disconnected
            report(error)
            return
        }

        self.driver = driver
        await readScreen()
        // A window still to choose is not a failed connection: the driver works, the caller picks.
        let mustChooseWindow = failure?.code == "ambiguous_window"
        connectionState = errorMessage == nil || mustChooseWindow ? .ready : .disconnected
        if connectionState == .ready {
            await ActivityBeacon.shared.markActive()
        }
    }

    @discardableResult
    public func disconnect() async -> URL? {
        let recording = await driver?.disconnect()
        driver = nil
        connectionState = .disconnected
        elements = []
        appLabel = nil
        appPackage = nil
        vanishedApps = []
        lastAction = nil
        lastDelivery = []
        screenOrigin = nil
        // `reading` keeps counting, so an alias from the previous connection never matches.
        past = [:]
        return recording
    }

    public func readScreen() async {
        guard let driver else { return }
        isReading = true
        defer { isReading = false }
        do {
            let hierarchy = try await driver.describeUI()
            elements = hierarchy.elements
            screenSize = hierarchy.screenSize
            appLabel = hierarchy.appLabel
            appPackage = hierarchy.appPackage
            vanishedApps = hierarchy.vanishedApps
            screenOrigin = hierarchy.screenOrigin
            failure = nil
            record(hierarchy.elements)
        } catch {
            report(error)
        }
    }

    /// Ejecuta la acción y vuelve a leer la pantalla. Además de que el árbol
    /// llega desactualizado si se lee enseguida, releer es obligatorio: los
    /// alias `@N` los cachea la última lectura, así que sin relectura el
    /// próximo tap apuntaría a la pantalla anterior.
    public func perform(_ action: DeviceAction) async {
        guard let driver else { return }
        isActing = true
        defer { isActing = false }
        lastDelivery = []
        await showPointer(for: action)
        do {
            lastDelivery = try await driver.perform(action)
        } catch {
            report(error)
            return
        }
        lastAction = action.caption
        failure = nil
        try? await Task.sleep(for: .milliseconds(600))
        await readScreen()
    }

    /// Mata la app, la vuelve a abrir y espera a que esté lista para leer. Si
    /// la app no estaba corriendo, terminate falla: es el caso normal.
    ///
    /// Estar en primer plano no alcanza: mientras la app no publica su árbol,
    /// sim-use devuelve un único elemento prestado de SpringBoard (el reloj de
    /// la status bar o el "Return to …"), y después viene un render parcial. Se
    /// espera a más de un elemento y a que el árbol no cambie entre dos lecturas
    /// seguidas. Si falla, deja el motivo en `errorMessage`.
    public func relaunch(_ bundleID: String, timeout: Duration = .seconds(15)) async -> Bool {
        guard let driver else { return false }
        do {
            try? await driver.terminate(bundleID: bundleID)
            try await driver.launch(bundleID: bundleID)
        } catch {
            report(error)
            return false
        }

        let deadline = ContinuousClock.now + timeout
        var previousCount = -1
        while ContinuousClock.now < deadline {
            await readScreen()
            let count = elements.count
            if appPackage == bundleID && count > 1 && count == previousCount {
                failure = nil
                return true
            }
            previousCount = count
            try? await Task.sleep(for: .milliseconds(500))
        }
        failure = UnexpectedError(message: "\(bundleID) wasn't in the foreground after \(timeout.components.seconds) s.")
        return false
    }

    // MARK: - Aliases bound to a reading

    /// Taps `@reading:alias`, the alias as the caller saw it in `reading`.
    public func tap(alias: Int, seenIn reading: Int) async {
        await act(onAlias: alias, seenIn: reading) { $0.tapAction }
    }

    /// Acts on `@reading:alias` with the action `build` makes for the element as it is now,
    /// after the same check as `tap`. For `set_value`, `toggle` and `select`.
    public func act(onAlias alias: Int, seenIn reading: Int, _ build: (UIElement) -> DeviceAction?) async {
        guard let before = past[reading] else { return report(InspectorError.unknownReading(reading)) }
        guard let index = before.firstIndex(where: { $0.alias == alias }) else {
            return report(InspectorError.unknownAlias(alias: alias, reading: reading))
        }
        await act(at: index, seenIn: reading, build)
    }

    /// Taps an element taken from `elements` while `reading` was current.
    public func tap(_ element: UIElement, seenIn reading: Int) async {
        // Re-reading an unchanged screen yields new ids under the same reading number.
        let current = reading == self.reading ? elements.firstIndex(where: { $0.id == element.id }) : nil
        guard let index = past[reading]?.firstIndex(where: { $0.id == element.id }) ?? current else {
            return report(InspectorError.unknownReading(reading))
        }
        await act(at: index, seenIn: reading) { $0.tapAction }
    }

    /// Re-reads first, so a screen that changed on its own since the caller looked is
    /// caught too. Aliases are positions in the flattened list: the element still means
    /// the same thing only if it and everything before it are unchanged. Changes after
    /// it, such as a streaming reply below, do not matter.
    private func act(at index: Int, seenIn reading: Int, _ build: (UIElement) -> DeviceAction?) async {
        guard driver != nil, let before = past[reading] else { return }
        await readScreen()
        guard failure == nil else { return }
        let now = elements
        let unchanged = now.count > index
            && zip(before.prefix(index + 1), now.prefix(index + 1)).allSatisfy(Self.sameSlot)
        guard unchanged else {
            return report(InspectorError.screenChanged(caption: before[index].caption, reading: reading, current: self.reading))
        }
        // No alias means sim-use found no handle for it; only a tap has a point to fall back on.
        guard let action = build(now[index]) else {
            return report(InspectorError.noHandle(caption: now[index].caption))
        }
        await perform(action)
    }

    // MARK: - Windows

    /// Throws instead of setting `failure`: listing is not a reading, and must not hide or
    /// replace the error of the last one.
    public func listWindows() async throws -> [WindowInfo] {
        guard let driver else { return [] }
        return try await driver.listWindows()
    }

    /// Points the driver at a window and reads it.
    public func chooseWindow(number: Int) async {
        guard let driver else { return }
        do {
            try await driver.chooseWindow(number: number)
        } catch {
            return report(error)
        }
        await readScreen()
    }

    /// Brings a window forward and reads it.
    public func bringToFront(window: Int?) async {
        guard let driver else { return }
        do {
            try await driver.bringToFront(window: window)
        } catch {
            return report(error)
        }
        await readScreen()
    }

    /// Bounds are left out: a scroll or a resize moves elements without changing what an alias points to.
    private static func sameSlot(_ a: UIElement, _ b: UIElement) -> Bool {
        a.alias == b.alias && a.type == b.type && a.region == b.region
            && a.identifier == b.identifier && a.label == b.label && a.text == b.text
    }

    private func record(_ elements: [UIElement]) {
        let latest = past[reading]
        let changed = latest.map { $0.count != elements.count || !zip($0, elements).allSatisfy(Self.sameSlot) } ?? true
        guard changed else { return }
        reading += 1
        past[reading] = elements
        past = past.filter { $0.key > reading - Self.keptReadings }
    }

    /// Tells the Fingertip app where the action lands, so it can draw a pointer there.
    /// Only for actions with a place on this Mac's screen.
    private func showPointer(for action: DeviceAction) async {
        guard let driver, let readOrigin = screenOrigin else { return }
        // Bounds are relative to the window, so a window moved since the reading only shifts the origin.
        let origin = await driver.currentScreenOrigin() ?? readOrigin
        let frame: CGRect
        let caption: String
        switch action {
        case .tap, .setValue, .toggle, .select:
            if let alias = action.alias, let element = elements.first(where: { $0.alias == alias }), !element.bounds.isEmpty {
                frame = element.bounds
                caption = element.caption
            } else if case .tap(_, let point) = action {
                frame = CGRect(origin: point, size: .zero)
                caption = action.caption
            } else {
                return
            }
        case .swipe(let from, _):
            frame = CGRect(origin: from, size: .zero)
            caption = action.caption
        default:
            return
        }
        await ActivityBeacon.shared.send(.pointer(frame: frame.offsetBy(dx: origin.x, dy: origin.y), caption: caption))
    }

    private func report(_ error: Error) {
        failure = fingertipError(error)
    }
}
