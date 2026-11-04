//
//  main.swift
//  fingertip-mcp
//
//  Servidor MCP por stdio para que Claude Code haga pruebas manuales sobre un
//  simulador iOS o una app de macOS. Se registra con:
//
//      claude mcp add fingertip -- <ruta>/fingertip-mcp
//
//  Terminales, editores con terminal, Claude y gestores de contraseñas quedan
//  bloqueados; `-e FINGERTIP_UNRESTRICTED=1` en el registro los libera.
//
//  Los permisos de macOS (Accesibilidad, Grabación de pantalla) los pide el
//  proceso responsable, que lanzado desde Claude Code es la terminal, no este
//  binario. Solo hacen falta para apps de macOS.
//

import AppKit

// ScreenCaptureKit asierta en `CGS_REQUIRE_INIT` en un binario de línea de
// comandos que no tocó NSApplication antes.
_ = NSApplication.shared

let session = Session()
let server = MCPServer(
    name: "fingertip",
    version: "0.4.0",
    instructions: """
    Prueba a mano un simulador iOS o una app de macOS: leé la pantalla, tocá, escribí, scrolleá y verificá. \
    Flujo típico: `list_targets` → `connect` → `relaunch_app` para arrancar limpio → `read_screen` → acciones \
    (cada una devuelve la pantalla nueva) → `screenshot` para verificar lo visual. Los alias `@L:N` llevan el \
    número de lectura: `tap` rechaza uno si la pantalla cambió antes de ese elemento. En pantallas densas, \
    `read_screen` con `skeleton` y después `region`. Cada error trae un código y `retry_safe`. \
    `run_instruction` delega una instrucción entera a Jev.
    """,
    tools: session.tools,
    status: session.status
)

// A signal ends the process without returning from `serve()`, which would leave a `simctl
// recordVideo` child recording forever. Close the recording first, then exit.
let signalQueue = DispatchQueue(label: "fingertip-mcp.signals")
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler { @Sendable in
        Task { @MainActor in
            await session.shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}

await server.serve()
await session.shutdown()
withExtendedLifetime(signalSources) {}
