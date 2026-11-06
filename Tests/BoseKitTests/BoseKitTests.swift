import XCTest

@testable import BoseKit

final class BoseKitTests: XCTestCase {

  // MARK: - BMAP Packet Tests

  func testPacketSerialization() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cnc,
      op: BMAPOperator.setGet.rawValue, payload: [0x0A, 0x01])
    XCTAssertEqual(pkt, [0x01, 0x05, 0x02, 0x02, 0x0A, 0x01])
  }

  func testPacketParsingValid() {
    let rawBytes: [UInt8] = [0x01, 0x07, 0x03, 0x04, 0xF6, 0x0A, 0x00, 0x00]
    let parsed = BMAPPacket.parse(rawBytes)
    XCTAssertNotNil(parsed)
    XCTAssertEqual(parsed?.functionBlock, 1)
    XCTAssertEqual(parsed?.functionID, 7)
    XCTAssertEqual(parsed?.operator, .status)
    XCTAssertEqual(parsed?.payload, [0xF6, 0x0A, 0x00, 0x00])
  }

  func testPacketParsingTruncated() {
    // Claims len 5, only 2 payload bytes
    let truncated: [UInt8] = [0x01, 0x07, 0x03, 0x05, 0x01, 0x02]
    let parsed = BMAPPacket.parse(truncated)
    XCTAssertNil(parsed)
  }

  // MARK: - CNC & Favorites Tests

  func testCncModeMapping() {
    XCTAssertEqual(NoiseMode.quiet.rawValue, 0)
    XCTAssertEqual(NoiseMode.aware.rawValue, 1)
    XCTAssertEqual(NoiseMode.quiet.label, "Quiet")
    XCTAssertEqual(NoiseMode.aware.label, "Aware")
  }

  func testCncFavoritesDefault() {
    let favs = CncFavorites()
    XCTAssertEqual(favs.activeIndex, 0)
    XCTAssertEqual(favs.preset0, 0)
    XCTAssertEqual(favs.preset1, 5)
    XCTAssertEqual(favs.preset2, 10)
    XCTAssertEqual(favs.level(for: 0), 0)
    XCTAssertEqual(favs.level(for: 1), 5)
    XCTAssertEqual(favs.level(for: 2), 10)
  }

  func testCncFavoritesCustom() {
    let favs = CncFavorites(activeIndex: 2, preset0: 2, preset1: 6, preset2: 10)
    XCTAssertEqual(favs.activeIndex, 2)
    XCTAssertEqual(favs.level(for: 1), 6)
  }

  // MARK: - Equalizer Tests

  func testEqualizerClamping() {
    let eq = EqualizerSettings(bass: 15, mid: -20, treble: 5)
    XCTAssertEqual(eq.bass, 10)  // Clamped to +10
    XCTAssertEqual(eq.mid, -10)  // Clamped to -10
    XCTAssertEqual(eq.treble, 5)
  }

  func testEqualizerSignedBytes() {
    // -10 dB in two's complement Int8 is 0xF6
    let minByte = UInt8(bitPattern: Int8(-10))
    XCTAssertEqual(minByte, 0xF6)

    // +10 dB in Int8 is 0x0A
    let maxByte = UInt8(bitPattern: Int8(10))
    XCTAssertEqual(maxByte, 0x0A)
  }

  // MARK: - Volume Tests

  func testVolumePercentage() {
    let mute = VolumeInfo(current: 0, max: 16)
    XCTAssertEqual(mute.percentage, 0)

    let half = VolumeInfo(current: 8, max: 16)
    XCTAssertEqual(half.percentage, 50)

    let max = VolumeInfo(current: 16, max: 16)
    XCTAssertEqual(max.percentage, 100)

    let step6 = VolumeInfo(current: 6, max: 16)
    XCTAssertEqual(step6.percentage, 38)
  }

  // MARK: - Touch Shortcuts Tests

  func testShortcutActions() {
    XCTAssertEqual(ShortcutAction.batteryLevel.rawValue, 3)
    XCTAssertEqual(ShortcutAction.spotifyTap.rawValue, 16)
    XCTAssertEqual(ShortcutAction.wakeWord.rawValue, 7)

    XCTAssertEqual(ShortcutAction.batteryLevel.label, "Read Battery Level")
    XCTAssertEqual(ShortcutAction.spotifyTap.label, "Spotify Tap")
    XCTAssertEqual(ShortcutAction.wakeWord.label, "Enable/Disable Wake Word")
  }

  // MARK: - Device Catalog Tests

  func testCatalogProfiles() {
    let nc700 = DeviceCatalog.profile(forProductID: 0x4024)
    XCTAssertNotNil(nc700)
    XCTAssertEqual(nc700?.codename, "goodyear")
    XCTAssertEqual(nc700?.defaultChannelID, 9)
    XCTAssertTrue(nc700?.usesDirectCNC == true)

    let ultraHP = DeviceCatalog.profile(forProductID: 0x4060)
    XCTAssertNotNil(ultraHP)
    XCTAssertEqual(ultraHP?.codename, "wolverine")
    XCTAssertEqual(ultraHP?.defaultChannelID, 2)
    XCTAssertFalse(ultraHP?.usesDirectCNC == true)

    let ultraEarbuds = DeviceCatalog.profile(forProductID: 0x4062)
    XCTAssertNotNil(ultraEarbuds)
    XCTAssertEqual(ultraEarbuds?.defaultChannelID, 2)
  }

  // MARK: - Connected Device Tests

  func testConnectedDeviceModel() {
    let dev = ConnectedDevice(
      macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", isConnected: true, isLocalHost: false,
      isActiveAudioSource: true)
    XCTAssertEqual(dev.macAddress, "AA:BB:CC:DD:EE:FF")
    XCTAssertEqual(dev.name, "Phone")
    XCTAssertTrue(dev.isConnected)
    XCTAssertFalse(dev.isLocalHost)
    XCTAssertTrue(dev.isActiveAudioSource)
  }
}
