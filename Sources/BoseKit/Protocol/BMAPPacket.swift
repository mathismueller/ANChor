import Foundation

/// BMAP (Bose Message Access Protocol) packet building and parsing.
public struct BMAPPacket: Equatable, Sendable {
    public let functionBlock: UInt8
    public let functionID: UInt8
    public let `operator`: BMAPOperator
    public let payload: [UInt8]

    public init(functionBlock: UInt8, functionID: UInt8, operator: BMAPOperator, payload: [UInt8] = []) {
        self.functionBlock = functionBlock
        self.functionID = functionID
        self.operator = `operator`
        self.payload = payload
    }

    /// Serializes into the wire format: `[fblock, funcID, op & 0x0F, payloadLen, ...payload]`
    public var rawBytes: [UInt8] {
        return [functionBlock, functionID, `operator`.rawValue & 0x0F, UInt8(payload.count)] + payload
    }

    /// Parses raw bytes into a BMAPPacket if valid
    public static func parse(_ bytes: [UInt8]) -> BMAPPacket? {
        guard bytes.count >= 4 else { return nil }
        let fblock = bytes[0]
        let funcID = bytes[1]
        guard let op = BMAPOperator(rawValue: bytes[2] & 0x0F) else { return nil }
        let len = Int(bytes[3])
        guard bytes.count >= 4 + len else { return nil }
        let payload = Array(bytes[4..<(4 + len)])
        return BMAPPacket(functionBlock: fblock, functionID: funcID, operator: op, payload: payload)
    }
}

public enum BMAPOperator: UInt8, Sendable {
    case set     = 0
    case get     = 1
    case setGet  = 2
    case status  = 3
    case error   = 4
    case start   = 5
    case result  = 6
}

public enum BMAPFunctionBlock {
    public static let deviceInfo: UInt8       = 0
    public static let settings: UInt8         = 1
    public static let battery: UInt8          = 2
    public static let deviceManagement: UInt8 = 4
    public static let audioManagement: UInt8  = 5
    public static let audioModes: UInt8       = 31 // 0x1F
}

public enum BMAPFunction {
    // Block 0: DeviceInfo
    public static let protocolVersion: UInt8 = 1
    public static let deviceVariant: UInt8   = 2
    public static let firmwareVersion: UInt8 = 5
    public static let serialNumber: UInt8    = 7

    // Block 1: Settings
    public static let productName: UInt8     = 2
    public static let voicePrompts: UInt8    = 3
    public static let cnc: UInt8             = 5
    public static let equalizer: UInt8       = 7
    public static let buttons: UInt8         = 9
    public static let multipoint: UInt8      = 10
    public static let sidetone: UInt8        = 11
    public static let autoOff: UInt8         = 12
    public static let cncFavorites: UInt8    = 15

    // Block 2: Battery
    public static let batteryLevel: UInt8    = 2
    public static let batteryState: UInt8    = 3

    // Block 4: DeviceManagement
    public static let listDevices: UInt8     = 4
    public static let peerDeviceInfo: UInt8  = 5
    public static let localMacAddress: UInt8 = 9

    // Block 5: AudioManagement
    public static let audioSource: UInt8     = 1
    public static let audioControl: UInt8    = 3
    public static let volume: UInt8          = 5

    // Block 31 (0x1F): AudioModes
    public static let allModes: UInt8        = 1
    public static let currentMode: UInt8     = 3
}

/// Helper function to construct wire packet bytes directly
public func makeBMAPPacket(fblock: UInt8, func_id: UInt8, op: UInt8, payload: [UInt8] = []) -> [UInt8] {
    return [fblock, func_id, op & 0x0F, UInt8(payload.count)] + payload
}
