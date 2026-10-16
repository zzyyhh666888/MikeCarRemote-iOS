//
//  CarProtocol.swift
//  MikeCarRemote
//
//  与 STM32 固件 app/my_usart.c 中 BTData_Process() 完全对应的 13 字节控制帧。
//
//  帧结构:
//  [0]    0xA5  帧头
//  [1]    ch0  rudder   转向   (中点 128)
//  [2]    ch1  throttle 油门   (中点 128，固件预留)
//  [3]    ch2  aileron  横移   (中点 128)
//  [4]    ch3  elevator 前后   (中点 128)
//  [5]    ch4  机械臂 X 增量   (中点 128)
//  [6]    ch5  机械臂 Y 增量   (中点 128)
//  [7]    ch6  机械臂腕部旋转  (中点 128)
//  [8]    ch7  claw 夹爪       (0...255 绝对位置)
//  [9]    开关位域 (bit0=sw0, bit1=sw1, bit3=sw3 安装模式)
//  [10]   保留 0x00
//  [11]   校验和 = (byte1 + ... + byte10) & 0xFF
//  [12]   0x5A  帧尾
//

import Foundation

/// 驾驶模式，对应固件 my_usart.c 中 sw0/sw1 组合出的 m4mode
enum DriveMode: Int, CaseIterable, Identifiable {
    case manual        = 0  // m4mode 0: sw0=0 sw1=0 手动，无陀螺保持
    case gyroHold      = 2  // m4mode 2: sw0=0 sw1=1 陀螺角度保持
    case avoidance     = 4  // m4mode 4: sw0=1 sw1=0 避障
    case holdAvoid     = 1  // m4mode 1: sw0=1 sw1=1 陀螺保持 + 避障

    var id: Int { rawValue }

    var swBits: UInt8 {
        switch self {
        case .manual:    return 0       // 00
        case .gyroHold:  return 1 << 1  // 01
        case .avoidance: return 1 << 0  // 10
        case .holdAvoid: return (1 << 0) | (1 << 1) // 11
        }
    }

    var label: String {
        switch self {
        case .manual:    return "手动"
        case .gyroHold:  return "陀螺保持"
        case .avoidance: return "避障"
        case .holdAvoid: return "保持+避障"
        }
    }
}

struct ControlFrame {
    // 有符号通道，范围 -128...127，0 为中点
    var rudder: Int = 0    // ch0
    var throttle: Int = 0  // ch1
    var aileron: Int = 0   // ch2
    var elevator: Int = 0  // ch3
    var armX: Int = 0      // ch4
    var armY: Int = 0      // ch5
    var armZ: Int = 0      // ch6
    var claw: Int = 0      // ch7, 0...255

    var switches: UInt8 = 0

    static let frameHead: UInt8 = 0xA5
    static let frameTail: UInt8 = 0x5A

    /// 摇杆归一化量 (-1...1) 转有符号通道值。
    /// 负向给到 -128、正向给到 127，与固件 `ch - 128` 的解析一致。
    static func scaledSigned(_ value: Double, deadZone: Double = 0.07) -> Int {
        var v = max(-1, min(1, value))
        if abs(v) < deadZone { v = 0 }
        if v >= 0 {
            return Int((v * 127.0).rounded())
        } else {
            return Int((v * 128.0).rounded())
        }
    }

    /// 夹爪滑条 (0...1) 转 0...255
    static func scaledClaw(_ value: Double) -> Int {
        let v = max(0, min(1, value))
        return Int((v * 255).rounded())
    }

    /// 编码为 13 字节数据帧
    func encode() -> Data {
        var bytes = [UInt8](repeating: 0, count: 13)
        bytes[0] = Self.frameHead

        let signedChannels = [rudder, throttle, aileron, elevator, armX, armY, armZ]
        for (index, value) in signedChannels.enumerated() {
            let clamped = max(-128, min(127, value))
            bytes[index + 1] = UInt8(bitPattern: Int8(clamped + 128))
        }
        bytes[8] = UInt8(max(0, min(255, claw)))

        bytes[9] = switches
        bytes[10] = 0x00

        var checksum: UInt8 = 0
        for i in 1...10 {
            checksum = checksum &+ bytes[i]
        }
        bytes[11] = checksum
        bytes[12] = Self.frameTail

        return Data(bytes)
    }

    /// 全部通道回中（夹爪保持为张开状态的中点值由调用方决定，这里给 0 仅用于校验）
    static func idle(switches: UInt8 = 0, claw: Int = 128) -> ControlFrame {
        ControlFrame(claw: claw, switches: switches)
    }
}
