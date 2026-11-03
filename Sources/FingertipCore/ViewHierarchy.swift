//
//  ViewHierarchy.swift
//  FingertipCore
//
//  Modelo de la pantalla, construido desde `sim-use ui --json --no-raw`.
//  No hay árbol: la API de accesibilidad de Apple devuelve una lista plana
//  (todas las entradas vienen con `depth: 1`), agrupada por región. Lo que
//  ordena la pantalla es `region`, no la anidación.
//

import CoreGraphics
import Foundation

public nonisolated struct UIElement: Identifiable, Hashable, Sendable {
    public let id = UUID()
    /// Alias `@N` del último `ui`: la forma preferida de tocar el elemento.
    public var alias: Int?
    public var identifier: String?
    public var text: String?
    public var label: String?
    public var type: String
    /// `Top`, `Content` o `Bottom`.
    public var region: String
    public var bounds: CGRect
    public var isEnabled: Bool
    /// Checkbox, radio o switch: si está marcado. `nil` en el resto y en iOS,
    /// donde sim-use no lo informa.
    public var isChecked: Bool? = nil

    /// Candidatos de tap. Es una lista negra a propósito: sirve tocar cualquier
    /// cosa con identidad, y muchas listas (SwiftUI, React Native) exponen sus
    /// filas como `StaticText` o `Icon`, no como `Cell`. Lo único que se saca
    /// son contenedores y chrome, que solo meterían ruido en el Choice.
    public var isActionable: Bool {
        ![
            "Application", "Window", "Other", "ScrollView",
            "CollectionView", "WebView", "Keyboard", "NavigationBar", "TabBar"
        ].contains(type)
    }

    /// Elementos donde tiene sentido escribir después de tocarlos.
    public var acceptsText: Bool {
        ["TextField", "SecureTextField", "SearchField", "TextView"].contains(type)
    }

    /// Respaldo para cuando el elemento no tiene alias.
    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Sin nada de esto, el elemento no se distingue de su contenedor.
    public var hasIdentity: Bool {
        identifier != nil || text != nil || label != nil
    }

    /// Lo que se muestra en la lista.
    public var caption: String {
        text ?? label ?? identifier ?? "—"
    }

    /// La acción de tap que le corresponde: alias si lo tiene, punto si no.
    public var tapAction: DeviceAction {
        .tap(alias: alias, point: center)
    }
}

public nonisolated struct ScreenHierarchy: Sendable {
    /// Lista plana, en el orden en que la imprime sim-use: es lo que ve Jev.
    public var elements: [UIElement]
    public var screenSize: CGSize
    /// Nombre de la app en primer plano, para mostrar en el inspector.
    public var appLabel: String?
    /// Bundle id de la app en primer plano: con esto se sabe si ya apareció la app bajo prueba.
    public var appPackage: String?
    /// Apps que estaban corriendo y ya no: si es la app bajo prueba, se murió.
    public var vanishedApps: [String]
    /// Where `bounds` start on the Mac's screen (global, top-left origin): the window's
    /// origin for a Mac app. `nil` on the simulator, whose points aren't on this screen.
    public var screenOrigin: CGPoint? = nil
}

// MARK: - Parseo

nonisolated struct SimUseScreenData: Decodable, Sendable {
    var appLabel: String?
    var appPackage: String?
    var entries: [SimUseEntry]
    var screen: SimUseRect
    var orientation: String?
}

nonisolated struct SimUseEntry: Decodable, Sendable {
    var aliases: Aliases
    var frame: SimUseRect
    var label: String?
    var value: String?
    var region: Region
    var role: String
    var states: [String]
    var uniqueId: String?

    nonisolated struct Aliases: Decodable, Sendable {
        var at: Int?
    }

    nonisolated struct Region: Decodable, Sendable {
        var kind: String
    }
}

nonisolated struct SimUseRect: Decodable, Sendable {
    var x: Double?
    var y: Double?
    var width: Double
    var height: Double

    var rect: CGRect {
        CGRect(x: x ?? 0, y: y ?? 0, width: width, height: height)
    }
}

nonisolated extension ScreenHierarchy {
    init(_ data: SimUseScreenData, vanished: [String]) {
        self.init(
            elements: data.entries.map(UIElement.init).filter { $0.hasIdentity && !$0.bounds.isEmpty },
            screenSize: data.screen.rect.size,
            appLabel: data.appLabel?.nilIfEmpty,
            appPackage: data.appPackage?.nilIfEmpty,
            vanishedApps: vanished
        )
    }
}

nonisolated extension UIElement {
    /// En `StaticText`/`TextView` el texto visible está en `label`, no en `value`.
    init(_ entry: SimUseEntry) {
        let isTextDisplay = entry.role == "StaticText" || entry.role == "TextView"
        let labelOrTitle = entry.label?.nilIfEmpty
        var text = entry.value?.nilIfEmpty
        var label: String?

        if isTextDisplay, text == nil {
            text = labelOrTitle
        } else {
            label = labelOrTitle
        }

        self.init(
            alias: entry.aliases.at,
            identifier: entry.uniqueId?.nilIfEmpty,
            text: text,
            label: label,
            type: entry.role,
            region: entry.region.kind,
            bounds: entry.frame.rect,
            isEnabled: !entry.states.contains("disabled")
        )
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
