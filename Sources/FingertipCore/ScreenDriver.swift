//
//  ScreenDriver.swift
//  FingertipCore
//
//  Lo que el agente necesita de un dispositivo: leer la pantalla, actuar,
//  capturarla y relanzar la app bajo prueba. El simulador lo resuelve con
//  sim-use + simctl; una app de macOS, con la API de Accesibilidad. JevAgent
//  y ScreenInspector solo ven este protocolo.
//

import Foundation

/// Lo que se elige en la barra lateral: un simulador o una app de macOS.
public nonisolated enum Target: Hashable, Sendable {
    case simulator(udid: String)
    case mac(MacApp)

    /// A Mac app with several windows is not read until one is chosen (`ambiguous_window`).
    public func makeDriver() -> any ScreenDriver {
        switch self {
        case .simulator(let udid): SimulatorDriver(udid: udid)
        case .mac(let app): MacDriver(app: app)
        }
    }
}

public nonisolated protocol ScreenDriver: Sendable {
    /// Nombre de la capa que maneja el dispositivo, para el estado en la UI.
    var name: String { get }
    /// Falla con un error legible si falta algo para manejar el dispositivo
    /// (el binario de sim-use, el permiso de Accesibilidad).
    func preflight() async throws
    func describeUI() async throws -> ScreenHierarchy
    /// Returns each strategy the driver tried and what it did; empty when there is nothing
    /// to report beyond the action itself (sim-use only says whether it ran).
    @discardableResult
    func perform(_ action: DeviceAction) async throws -> [DeliveryStep]
    /// The app's windows, on a driver that reads one of several. Empty on the simulator.
    func listWindows() async throws -> [WindowInfo]
    /// Reads and actions go to this window from now on, until it closes or the app relaunches.
    func chooseWindow(number: Int) async throws
    /// Brings `window` (else the chosen or only one) to the front, switching Space if needed,
    /// and chooses it. Nothing on the simulator.
    func bringToFront(window: Int?) async throws
    /// PNG de lo que se ve: la pantalla del simulador o la ventana de la app.
    func screenshot() async throws -> Data
    /// Starts a video of the device (the simulator screen, or the app's window) into `url`.
    /// Fails with `already_recording` if one is running.
    func startRecording(to url: URL) async throws
    /// Ends the recording and returns the finished file. Fails with `not_recording` if none runs.
    func stopRecording() async throws -> URL
    func launch(bundleID: String) async throws
    /// Falla si la app no estaba corriendo: el caller decide si eso importa.
    func terminate(bundleID: String) async throws
    /// Closes what the driver holds open. Returns the file of a recording it had to end, if any.
    @discardableResult
    func disconnect() async -> URL?
    /// Where the window the last reading measured from sits on this Mac's screen right
    /// now, read live so a window moved since then still lines up. `nil` off the Mac.
    func currentScreenOrigin() async -> CGPoint?
}

public nonisolated extension ScreenDriver {
    func currentScreenOrigin() async -> CGPoint? { nil }
    func listWindows() async throws -> [WindowInfo] { [] }
    func chooseWindow(number: Int) async throws {}
    func bringToFront(window: Int?) async throws {}
}

public nonisolated struct SimulatorDriver: ScreenDriver {
    public let udid: String
    private let simUse = SimUse()
    private let simctl = Simctl()
    private let recorder = SimulatorRecorder()

    public init(udid: String) {
        self.udid = udid
    }

    public var name: String { "sim-use" }

    public func preflight() async throws {
        guard await simUse.binaryPath() != nil else { throw SimUseError.notInstalled }
    }

    public func describeUI() async throws -> ScreenHierarchy {
        try await simUse.describeUI(udid: udid)
    }

    @discardableResult
    public func perform(_ action: DeviceAction) async throws -> [DeliveryStep] {
        try await simUse.perform(action, udid: udid)
        return []
    }

    public func screenshot() async throws -> Data {
        try await simctl.screenshot(udid: udid)
    }

    public func startRecording(to url: URL) async throws {
        try await simctl.validate(udid: udid)
        try await recorder.start(udid: udid, to: url)
    }

    public func stopRecording() async throws -> URL {
        try await recorder.stop()
    }

    public func launch(bundleID: String) async throws {
        try await simctl.launch(bundleID: bundleID, udid: udid)
    }

    public func terminate(bundleID: String) async throws {
        try await simctl.terminate(bundleID: bundleID, udid: udid)
    }

    /// El daemon se va solo a los 600 s, pero pararlo explícitamente deja el
    /// simulador libre cuando el usuario termina.
    @discardableResult
    public func disconnect() async -> URL? {
        let recording = await closeRecording()
        await simUse.stopDaemon(udid: udid)
        return recording
    }

    private func closeRecording() async -> URL? {
        do {
            return try await recorder.stop()
        } catch RecordingError.notRecording {
            return nil
        } catch {
            FileHandle.standardError.write(Data("recording: no pude cerrar la grabación al desconectar: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }
}
