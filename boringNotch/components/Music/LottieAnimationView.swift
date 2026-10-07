//
//  LottieAnimationContainer.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 29..
//

import SwiftUI
import Defaults

struct LottieAnimationContainer: View {
    @Default(.selectedVisualizer) var selectedVisualizer
    var body: some View {
        if let selectedVisualizer {
            LottieView(url: selectedVisualizer.url, speed: selectedVisualizer.speed, loopMode: .loop)
        } else {
            OmniDDefaultVisualizer()
        }
    }
}

private struct OmniDDefaultVisualizer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let barWidth = max(1.5, proxy.size.width / 11)
                HStack(alignment: .center, spacing: barWidth * 0.55) {
                    ForEach(0..<5, id: \.self) { index in
                        let phase = time * 4.2 + Double(index) * 0.9
                        let level = reduceMotion ? 0.55 : 0.28 + abs(sin(phase)) * 0.72
                        Capsule(style: .continuous)
                            .fill(Color.effectiveAccent)
                            .frame(width: barWidth, height: max(3, proxy.size.height * level))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    LottieAnimationContainer()
}
