//
//  ContentView.swift
//  MikeCarRemote
//
//  参考 SayHi.apk 布局：8 开关 + 3 摇杆 + 2 滑条
//

import SwiftUI

/// SW1-SW8 开关标签与字节位的对应（与固件 my_usart.c 的 sw[0..7] 一致）
enum SwitchConfig {
    static let labels: [String] = [
        "SW1避障", "SW2自稳", "SW3跟随", "SW4安装",
        "SW5", "SW6", "SW7", "SW8",
    ]
}

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

    // 三个摇杆：左下=左手(转向/油门)，中=机械臂(X/Y)，右下=右手(横移/前后)
    @State private var centerX = 0.0; @State private var centerY = 0.0
    @State private var leftBotX = 0.0; @State private var leftBotY = 0.0
    @State private var rightBotX = 0.0; @State private var rightBotY = 0.0

    // SW1-SW8 独立开关
    @State private var swStates: [Bool] = Array(repeating: false, count: 8)

    // 滑条
    @State private var claw: Double = 0.0   // 0...1
    @State private var wristZ: Double = 0.5 // 0...1 (映射到 0...255)

    @State private var emergency = false
    @State private var showScanner = false

    // 40Hz 发送
    private let frameTimer = Timer.publish(every: 0.025, tolerance: 0.005,
                                           on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if ble.state == .ready || ble.state == .discovering {
                consoleView
            } else {
                connectView
            }
        }
        .sheet(isPresented: $showScanner) {
            ScannerView(ble: ble)
        }
        .alert("蓝牙提示",
               isPresented: Binding(get: { ble.lastError != nil },
                                    set: { if !$0 { ble.clearError() } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(ble.lastError ?? "")
        }
        .onReceive(frameTimer) { _ in
            guard ble.isReady else { return }
            ble.send(makeFrame().encode())
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                centerX = 0; centerY = 0
                leftBotX = 0; leftBotY = 0
                rightBotX = 0; rightBotY = 0
                emergency = true
                ble.send(makeFrame().encode())
            }
        }
    }

    // MARK: - 连接页

    private var connectView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "car.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("麦轮小车遥控").font(.title.bold())
                Text("蓝牙 BLE 直连 · 支持车体与机械臂控制")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            statusCard

            Button {
                showScanner = true
            } label: {
                Label("扫描并连接", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .disabled(ble.state == .bluetoothOff)

            Text("仅支持 BLE 蓝牙低功耗透传模块（如 HC-08、JDY-25M/33、CH9141、DX-BT22 等）。\nHC-05/HC-06 等经典蓝牙模块 iPhone 无法连接，需更换 BLE 模块。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
    }

    private var statusColor: Color {
        switch ble.state {
        case .scanning, .connecting, .discovering: return .orange
        case .bluetoothOff, .unavailable:         return .red
        default:                                  return .secondary
        }
    }

    private var statusText: String {
        switch ble.state {
        case .scanning:     return "正在搜索设备…"
        case .connecting:   return "正在连接…"
        case .discovering:  return "正在建立透传通道…"
        case .ready:        return "已连接"
        case .bluetoothOff: return "蓝牙已关闭，请先打开蓝牙"
        case .unavailable(let msg): return msg
        case .disconnected: return "未连接，将自动尝试重连上次设备"
        }
    }

    // MARK: - 控制台（参考 SayHi.apk 布局）

    private var consoleView: some View {
        ScrollView {
            VStack(spacing: 12) {
                connectionBar

                // 标题
                HStack {
                    Image(systemName: "car.fill")
                        .foregroundStyle(.tint)
                    Text("麦轮小车遥控")
                        .font(.headline)
                    Spacer()
                    if let name = ble.connectedName {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                            Text(name)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // SW1-SW8 开关面板（2x4 网格）
                switchGrid

                // 三个摇杆（与 SayHi 一致）：
                // 左下=左手(仅转向/单轴)，顶部中=机械臂(X/Y)，右下=右手(横移/前后)
                HStack(alignment: .bottom, spacing: 6) {
                    JoystickView(x: $leftBotX, y: $leftBotY,
                                 title: "左手",
                                 xAxisLabel: "转向",
                                 yAxisLabel: "",
                                 enabled: ble.isReady && !emergency,
                                 lockHorizontal: true)
                    JoystickView(x: $centerX, y: $centerY,
                                 title: "机械臂",
                                 xAxisLabel: "大臂左右",
                                 yAxisLabel: "大臂前后",
                                 enabled: ble.isReady && !emergency)
                    JoystickView(x: $rightBotX, y: $rightBotY,
                                 title: "右手",
                                 xAxisLabel: "横移",
                                 yAxisLabel: "前后",
                                 enabled: ble.isReady && !emergency)
                }
                .padding(.horizontal, 4)

                // 滑条区（夹爪 + 腕转）
                slidersCard

                // 急停
                Button {
                    toggleEmergency()
                } label: {
                    Label(emergency ? "解除急停" : "急停",
                          systemImage: emergency ? "play.fill" : "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(emergency ? .green : .red)
                .padding(.horizontal)
                .disabled(ble.state != .ready)

                channelMonitor
            }
            .padding(.vertical)
        }
    }

    // MARK: - 开关网格（SayHi 风格：SW1-SW8）

    private var switchGrid: some View {
        VStack(spacing: 6) {
            // 上半行 SW1-SW4
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    swButton(index: i)
                }
            }
            // 下半行 SW5-SW8
            HStack(spacing: 6) {
                ForEach(4..<8) { i in
                    swButton(index: i)
                }
            }
        }
        .padding(8)
        .background(cardBackground)
        .padding(.horizontal)
    }

    private func swButton(index: Int) -> some View {
        let label = SwitchConfig.labels[index]
        let isOn = swStates[index]
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                swStates[index].toggle()
            }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isOn ? Color.accentColor : Color(.tertiarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isOn ? Color.accentColor : Color(.systemGray4), lineWidth: 1)
                )
        }
        .disabled(!ble.isReady)
        .buttonStyle(.plain)
    }

    private var slidersCard: some View {
        VStack(spacing: 12) {
            // 夹爪
            HStack(spacing: 8) {
                Text("夹爪")
                    .font(.subheadline)
                    .frame(width: 36, alignment: .leading)
                Slider(value: $claw, in: 0...1)
                    .disabled(!ble.isReady)
                HStack(spacing: 4) {
                    Button("张开") { withAnimation { claw = 1 } }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button("闭合") { withAnimation { claw = 0 } }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            // 腕转
            HStack(spacing: 8) {
                Text("腕转")
                    .font(.subheadline)
                    .frame(width: 36, alignment: .leading)
                Slider(value: $wristZ, in: 0...1)
                    .disabled(!ble.isReady)
                Button("回中") { withAnimation { wristZ = 0.5 } }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding()
        .background(cardBackground)
        .padding(.horizontal)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(.secondarySystemBackground))
    }

    // MARK: - 顶部连接条

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ble.state == .ready ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(ble.connectedName ?? "BLE 设备")
                    .font(.subheadline.weight(.semibold))
                Text(ble.state == .ready ? "透传已就绪 · 40Hz" : "正在建立透传通道…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if ble.state == .ready {
                    Text("TX: \(ble.txCharacteristicUUID ?? "无")\(ble.rxCharacteristicUUID.map { "  RX: \($0)" } ?? "")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("已发 \(ble.sentFrameCount) 帧")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(ble.sentFrameCount > 0 ? .green : .red)
                }
            }
            Spacer()
            Button {
                ble.disconnect()
            } label: {
                Text("断开").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(cardBackground)
        .padding(.horizontal)
    }

    // MARK: - 通道监测

    private var channelMonitor: some View {
        let f = makeFrame()
        return VStack(spacing: 4) {
            Text(String(format: "转向 %d   前后 %d   横移 %d   油门 %d",
                        f.rudder, f.aileron, f.elevator, f.throttle))
            Text(String(format: "臂X %d   臂Y %d   腕转 %d   夹爪 %d   SW 0x%02X",
                        f.armX, f.armY, f.armZ, f.claw, Int(f.switches)))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: - 帧组装与动作

    private func makeFrame() -> ControlFrame {
        var sw: UInt8 = 0
        for i in 0..<8 {
            if swStates[i] { sw |= (1 << i) }
        }

        let clawValue = ControlFrame.scaledClaw(claw)

        if emergency {
            return ControlFrame(claw: clawValue, switches: sw)
        }

        var f = ControlFrame()
        // 左手摇杆（单轴）：ch0=转向；ch1 固定中位（该车固件中油门不参与行走）
        // 转向方向：左推=左转、右推=右转（电机对调后已验证）
        var turn = ControlFrame.scaledSigned(leftBotX)
        // 右手摇杆：该车电机接线导致 ch2=前后、ch3=横移。
        var fwd  = ControlFrame.scaledSigned(rightBotY)
        var lat  = ControlFrame.scaledSigned(rightBotX)
        // 预限幅：固件混控为 motor = ±30*ch2 ±20*ch3 ±20*ch0（Turn_Pwm=20*rudder），
        // 而固件 PWM_Limiting 有 bug（motor3/motor4 超限时会改写 motor2 的值和符号），
        // 任一电机 |值| 超过 ±3199 就会触发。这里按固件公式预先估算最大负载，
        // 超限时把三个通道整体等比缩小，保证任何摇杆组合都不触发该 bug。
        // 注意：仅覆盖开环模式；SW2自稳闭环的 Turn_Pwm 由固件 PD 自算，不受此限。
        let load = 30 * abs(fwd) + 20 * abs(lat) + 20 * abs(turn)
        if load > 3199 {
            let s = 3199.0 / Double(load)
            fwd  = Int((Double(fwd)  * s).rounded())
            lat  = Int((Double(lat)  * s).rounded())
            turn = Int((Double(turn) * s).rounded())
        }
        f.rudder   = turn
        f.throttle = 0
        f.aileron  = fwd
        f.elevator = lat
        // 中间摇杆：机械臂 X/Y = ch4/ch5
        f.armX     = ControlFrame.scaledSigned(centerX)
        f.armY     = ControlFrame.scaledSigned(centerY)
        f.armZ     = ControlFrame.scaledSigned((wristZ - 0.5) * 2) // 0...1 -> -1...1
        f.claw     = clawValue
        f.switches = sw
        return f
    }

    private func toggleEmergency() {
        emergency.toggle()
        if emergency {
            centerX = 0; centerY = 0
            leftBotX = 0; leftBotY = 0
            rightBotX = 0; rightBotY = 0
        }
    }
}

// MARK: - 扫描设备页

struct ScannerView: View {
    @ObservedObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if ble.devices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在搜索附近的 BLE 设备…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ble.devices) { device in
                        Button {
                            ble.connect(device)
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text(device.id.uuidString)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(device.rssi.intValue == 127 ? "—" : "\(device.rssi.intValue) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("若列表中没有小车模块，请确认：模块已通电、为 BLE 类型，且没有被其他手机占用连接。")
                }
            }
            .navigationTitle("选择蓝牙设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        ble.stopScan()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新扫描") { ble.startScan() }
                }
            }
            .onAppear { ble.startScan() }
            .onChange(of: ble.state) { newState in
                if newState == .connecting || newState == .discovering || newState == .ready {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
