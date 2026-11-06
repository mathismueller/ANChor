import Foundation

// MARK: - Noise Modes

public enum NoiseMode: UInt8, CaseIterable, Sendable {
    case quiet = 0
    case aware = 1

    public var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .aware: return "Aware"
        }
    }

    /// SF Symbol for menus and status bar
    public var symbolName: String {
        switch self {
        case .quiet: return "speaker.slash.fill"
        case .aware: return "ear"
        }
    }
}

// MARK: - Battery Info

public struct BatteryInfo: Equatable, Sendable {
    public var single: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public init(single: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.single = single
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }

    public var isSingleBattery: Bool {
        return single != nil
    }

    public var lowestLevel: Int? {
        if let s = single { return s }
        let levels = [left, right, caseLevel].compactMap { $0 }
        return levels.min()
    }

    public var hasData: Bool {
        return single != nil || left != nil || right != nil || caseLevel != nil
    }
}

// MARK: - Equalizer

public struct EqBand: Equatable, Sendable {
    public let id: UInt8
    public let name: String
    public let min: Int
    public let max: Int
    public var current: Int

    public init(id: UInt8, name: String, min: Int = -10, max: Int = 10, current: Int = 0) {
        self.id = id
        self.name = name
        self.min = min
        self.max = max
        self.current = current
    }

    public static let bassId: UInt8 = 0
    public static let midId: UInt8 = 1
    public static let trebleId: UInt8 = 2
}

public struct EqualizerSettings: Equatable, Sendable {
    public var bass: Int
    public var mid: Int
    public var treble: Int

    public init(bass: Int = 0, mid: Int = 0, treble: Int = 0) {
        self.bass = bass
        self.mid = mid
        self.treble = treble
    }
}

// MARK: - Sidetone (Self Voice during calls)

public enum SidetoneLevel: UInt8, CaseIterable, Sendable {
    case off    = 0
    case high   = 1
    case medium = 2
    case low    = 3

    public var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}

// MARK: - Device Metadata

public struct DeviceMetadata: Equatable, Sendable {
    public var firmwareVersion: String?
    public var protocolVersion: String?
    public var serialNumber: String?
    public var modelName: String?
    public var productID: UInt16?

    public init(
        firmwareVersion: String? = nil,
        protocolVersion: String? = nil,
        serialNumber: String? = nil,
        modelName: String? = nil,
        productID: UInt16? = nil
    ) {
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.serialNumber = serialNumber
        self.modelName = modelName
        self.productID = productID
    }
}
