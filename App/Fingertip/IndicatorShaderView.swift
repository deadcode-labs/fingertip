//
//  IndicatorShaderView.swift
//  Fingertip
//

import SwiftUI

struct IndicatorShaderView: View {
    // El tiempo absoluto (segundos desde 2001) pierde toda precisión en un
    // float32 dentro del shader — el ruido salía en blanco. Relativo al
    // momento en que arranca la vista, se queda chico.
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.white)
                    .colorEffect(
                        ShaderLibrary.indicatorSmoke(
                            .float(context.date.timeIntervalSince(start)),
                            .float(geometry.size.width),
                            .float(geometry.size.height)
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }
}
