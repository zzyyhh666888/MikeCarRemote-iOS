//
//  JoystickView.swift
//  MikeCarRemote
//
//  双轴虚拟摇杆，输出归一化的 x/y（-1...1），松手自动回中。
//  y 轴向上为正（对应小车前进 / 机械臂向前）。
//

import SwiftUI

struct JoystickView: View {
    @Binding var x: Double
    @Binding var y: Double

    let title: String
    let xAxisLabel: String
    let yAxisLabel: String
    var enabled: Bool = true
    var onReset: (() -> Void)? = nil

    private let baseSize: CGFloat = 150
    private let knobSize: CGFloat = 62
    private var travelRadius: CGFloat { (baseSize - knobSize) / 2 }

    @State private var knobOffset: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? .primary : .secondary)

            ZStack {
                // 底座
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: baseSize, height: baseSize)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(.systemGray3), lineWidth: 1)
                    )

                // 十字参考线
                Group {
                    Rectangle()
                        .fill(Color(.systemGray3))
                        .frame(width: 1.5, height: baseSize - 18)
                    Rectangle()
                        .fill(Color(.systemGray3))
                        .frame(width: baseSize - 18, height: 1.5)
                }
                .opacity(0.6)

                // 方向箭头提示
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(.systemGray2))
                    .offset(y: -baseSize / 2 + 16)

                // 摇杆头
                Circle()
                    .fill(knobColor)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(radius: dragging ? 6 : 3, y: 2)
                    .offset(knobOffset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged(handleDrag)
                            .onEnded { _ in handleRelease() }
                    )
            }
            .frame(width: baseSize, height: baseSize)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: knobOffset)

            HStack(spacing: 12) {
                Text("↔ \(xAxisLabel)")
                Text("↕ \(yAxisLabel)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .onChange(of: enabled) { isEnabled in
            if !isEnabled { reset() }
        }
    }

    private var knobColor: Color {
        if !enabled { return Color(.systemGray2) }
        return dragging ? Color.accentColor : Color(.systemGray2)
    }

    private func handleDrag(_ value: DragGesture.Value) {
        guard enabled else { return }
        dragging = true

        // 视图坐标 y 向下，取反后上推为正
        var dx = value.translation.width
        var dy = -value.translation.height

        let distance = sqrt(dx * dx + dy * dy)
        if distance > travelRadius {
            let scale = travelRadius / distance
            dx *= scale
            dy *= scale
        }

        knobOffset = CGSize(width: dx, height: -dy)
        x = Double(dx / travelRadius)
        y = Double(dy / travelRadius)
    }

    private func handleRelease() {
        dragging = false
        reset()
        onReset?()
    }

    private func reset() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) {
            knobOffset = .zero
        }
        x = 0
        y = 0
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var x = 0.0
        @State private var y = 0.0
        var body: some View {
            JoystickView(x: $x, y: $y,
                         title: "车体移动",
                         xAxisLabel: "转向",
                         yAxisLabel: "前后")
        }
    }
    return PreviewWrapper()
}
