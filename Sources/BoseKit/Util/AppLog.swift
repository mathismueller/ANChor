import Foundation
import os

/// Unified logging channels for ANChor and BoseKit.
public enum AppLog {
  public static let subsystem = "com.anchor.app"

  /// Bluetooth connection, RFCOMM channel lifecycle, discovery, and reconnections.
  public static let bluetooth = Logger(subsystem: subsystem, category: "bluetooth")

  /// Raw BMAP packets, packet serialization/deserialization, and hex dumps.
  public static let `protocol` = Logger(subsystem: subsystem, category: "protocol")

  /// Device state changes: noise control, battery, EQ, volume, device metadata.
  public static let device = Logger(subsystem: subsystem, category: "device")

  /// Menu bar UI actions: clicks, slider changes, and menu lifecycle.
  public static let ui = Logger(subsystem: subsystem, category: "ui")
}
