//
//  WelcomeView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import SwiftUI
import SwiftUIIntrospect

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Image("spotlight")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.bottom)
                    .blur(radius: 3)
                    .offset(y: -5)
                    .background(SparkleView().opacity(0.6))
                VStack(spacing: 8) {
                    Image("OmniDPodIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .padding(.bottom, 8)
                    Text("OmniD-Pod")
                        .font(.system(.largeTitle, design: .default))
                        .fontWeight(.semibold)
                    Text("欢迎")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 30)
                    Button {
                        onGetStarted?()
                    } label: {
                        Text("开始使用")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(OmniDPodPrimaryButtonStyle())
                }
                .padding(.top)
            }
            
            Text("DoubleOne · 基于 Boring Notch 开源项目")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
                .padding(.bottom, 36)
                .blendMode(.overlay)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeView()
}
