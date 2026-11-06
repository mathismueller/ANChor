import Foundation

public struct DeviceProfile: Equatable, Sendable {
  public let name: String
  public let codename: String
  public let productID: UInt16?
  public let defaultChannelID: UInt8
  public let usesDirectCNC: Bool
  public let hasEqualizer: Bool
  public let isEarbuds: Bool

  public init(
    name: String,
    codename: String,
    productID: UInt16?,
    defaultChannelID: UInt8,
    usesDirectCNC: Bool,
    hasEqualizer: Bool = true,
    isEarbuds: Bool = false
  ) {
    self.name = name
    self.codename = codename
    self.productID = productID
    self.defaultChannelID = defaultChannelID
    self.usesDirectCNC = usesDirectCNC
    self.hasEqualizer = hasEqualizer
    self.isEarbuds = isEarbuds
  }
}

public enum DeviceCatalog {
  public static let knownProfiles: [UInt16: DeviceProfile] = [
    // Bose Noise Cancelling Headphones 700 (goodyear)
    0x4024: DeviceProfile(
      name: "Noise Cancelling Headphones 700",
      codename: "goodyear",
      productID: 0x4024,
      defaultChannelID: 9,
      usesDirectCNC: true,
      hasEqualizer: true,
      isEarbuds: false
    ),
    // QC Ultra Earbuds (2nd Gen - edith)
    0x4062: DeviceProfile(
      name: "QC Ultra Earbuds (2nd Gen)",
      codename: "edith",
      productID: 0x4062,
      defaultChannelID: 2,
      usesDirectCNC: false,
      hasEqualizer: true,
      isEarbuds: true
    ),
    // QC Ultra Earbuds (1st Gen - scotty)
    0x4072: DeviceProfile(
      name: "QC Ultra Earbuds (1st Gen)",
      codename: "scotty",
      productID: 0x4072,
      defaultChannelID: 2,
      usesDirectCNC: false,
      hasEqualizer: true,
      isEarbuds: true
    ),
    // QC Ultra Headphones (wolverine)
    0x4060: DeviceProfile(
      name: "QC Ultra Headphones",
      codename: "wolverine",
      productID: 0x4060,
      defaultChannelID: 2,
      usesDirectCNC: false,
      hasEqualizer: true,
      isEarbuds: false
    ),
    // QC Earbuds (1st Gen - lando)
    0x402F: DeviceProfile(
      name: "QC Earbuds",
      codename: "lando",
      productID: 0x402F,
      defaultChannelID: 8,
      usesDirectCNC: true,
      hasEqualizer: true,
      isEarbuds: true
    ),
    // QC45 (fuji)
    0x403E: DeviceProfile(
      name: "QuietComfort 45",
      codename: "fuji",
      productID: 0x403E,
      defaultChannelID: 8,
      usesDirectCNC: false,
      hasEqualizer: true,
      isEarbuds: false
    ),
  ]

  public static let boseVendorID: UInt16 = 0x009E

  public static let knownNamePatterns = [
    "QC Ultra",
    "QuietComfort Ultra",
    "QuietComfort Earbuds",
    "QC Earbuds",
    "NC 700",
    "NC700",
    "Bose 700",
    "Noise Cancelling 700",
    "QuietComfort",
    "Bose",
  ]

  public static func profile(forProductID pid: UInt16) -> DeviceProfile? {
    return knownProfiles[pid]
  }
}
