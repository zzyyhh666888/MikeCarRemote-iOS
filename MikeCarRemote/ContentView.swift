//
//  ContentView.swift
//  MikeCarRemote
//
//  麦轮工程小车 + 机械臂蓝牙遥控主界面。
//

import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

    // 左摇杆：转向 / 前后；右摇杆：横移·油门 或 机械臂 X/Y
    @State private var leftX = 0.0
    @State private var leftY = 0.0
    @State private var rightX = 0.0
    @State private var rightY = 0.0

    enum RightStickFunction: Int, CaseIterable {
        case drive, arm
        var label: String { self == .drive ? "麦轮移动" : "机械臂" }
    }
    @State private var rightFunction: RightStickFunction = .drive

    @State private var driveMode: DriveMode = .manual
    @State private var installMode = false
    @State private var wristZ = 0.0       // -1...1
    @State private var claw: Double = 0.5 // 0...1
    @State private var emergency = false
    @State private var showScanner = false

    // 40Hz 发送。13 字节 * 40 = 520 B/s，低于 9600 波特率上限，固件约 300ms 无帧即失控停车
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
                // 进入后台/锁屏：立即发一帧中位帧，之后由固件失控保护停车
                leftX = 0; leftY = 0; rightX = 0; rightY = 0; wristZ = 0
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

    // MARK: - 控制台

    private var consoleView: some View {
        ScrollView {
            VStack(spacing: 18) {
                connectionBar

                // 驾驶模式
                VStack(alignment: .leading, spacing: 8) {
                    Text("驾驶模式").font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("驾驶模式", selection: $driveMode) {
                        ForEach(DriveMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(ble.state != .ready)

                    Toggle("机械臂安装回中模式 (sw3)", isOn: $installMode)
                        .font(.subheadline)
                }
                .padding()
                .background(cardBackground)
                .padding(.horizontal)

                // 双摇杆
                HStack(alignment: .bottom, spacing: 10) {
                    JoystickView(x: $leftX, y: $leftY,
                                 title: "左摇杆",
                                 xAxisLabel: "转向",
                                 yAxisLabel: "前进/后退",
                                 enabled: ble.isReady)
                    Spacer()
                    JoystickView(x: $rightX, y: $rightY,
                                 title: "右摇杆（\(rightFunction.label)）",
                                 xAxisLabel: rightFunction == .drive ? "横移" : "大臂左右",
                                 yAxisLabel: rightFunction == .drive ? "油门(预留)" : "大臂前后",
                                 enabled: ble.isReady)
                        .id(rightFunction)
                }
                .padding(.horizontal, 8)

                Picker("右摇杆功能", selection: $rightFunction) {
                    ForEach(RightStickFunction.allCases, id: \.self) { fn in
                        Text(fn.label).tag(fn)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: rightFunction) { _ in
                    rightX = 0; rightY = 0
                }

                // 腕部与夹爪
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Text("腕转").font(.subheadline).frame(width: 34, alignment: .leading)
                        Slider(value: $wristZ, in: -1...1)
                            .disabled(!ble.isReady)
                        Button("回中") { withAnimation { wristZ = 0 } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    HStack(spacing: 10) {
                        Text("夹爪").font(.subheadline).frame(width: 34, alignment: .leading)
                        Slider(value: $claw, in: 0...1)
                            .disabled(!ble.isReady)
                        Button("张开") { withAnimation { claw = 0 } }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("闭合") { withAnimation { claw = 1 } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding()
                .background(cardBackground)
                .padding(.horizontal)

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
            Text(String(format: "转向 %d   横移 %d   前后 %d   油门 %d",
                        f.rudder, f.aileron, f.elevator, f.throttle))
            Text(String(format: "臂X %d   臂Y %d   腕转 %d   夹爪 %d   SW 0x%02X",
                        f.armX, f.armY, f.armZ, f.claw, Int(f.switches)))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: - 帧组装与动作

    private func currentSwitches() -> UInt8 {
        var sw = driveMode.swBits
        if installMode { sw |= 0x08 } // sw3
        return sw
    }

    private func makeFrame() -> ControlFrame {
        let sw = currentSwitches()
        let clawValue = ControlFrame.scaledClaw(claw)

        if emergency {
            return ControlFrame(claw: clawValue, switches: sw)
        }

        var f = ControlFrame()
        f.rudder = ControlFrame.scaledSigned(leftX)
        f.elevator = ControlFrame.scaledSigned(leftY)

        if rightFunction == .drive {
            f.aileron = ControlFrame.scaledSigned(rightX)
            f.throttle = ControlFrame.scaledSigned(rightY)
        } else {
            f.armX = ControlFrame.scaledSigned(rightX)
            f.armY = ControlFrame.scaledSigned(rightY)
        }
        f.armZ = ControlFrame.scaledSigned(wristZ)
        f.claw = clawValue
        f.switches = sw
        return f
    }

    private func toggleEmergency() {
        emergency.toggle()
        if emergency {
            leftX = 0; leftY = 0
            rightX = 0; rightY = 0
            wristZ = 0
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
