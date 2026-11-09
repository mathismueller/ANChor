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
    XCTAssertEqual(NoiseMode.quiet.symbolName, "waveform.slash")
    XCTAssertEqual(NoiseMode.aware.symbolName, "ear")
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

  // MARK: - Notifications & Informative Blocks

  func testNotificationsEnablePacket() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.notification, funcID: BMAPFunction.notificationsByFblock,
      op: BMAPOperator.setGet.rawValue, payload: [0x01, 0x00, 0x05, 0x02, 0x37])
    XCTAssertEqual(pkt, [0x09, 0x02, 0x02, 0x05, 0x01, 0x00, 0x05, 0x02, 0x37])
  }

  func testNewFunctionConstants() {
    XCTAssertEqual(BMAPFunctionBlock.notification, 9)
    XCTAssertEqual(BMAPFunctionBlock.authentication, 18)
    XCTAssertEqual(BMAPFunction.standbyTimer, 4)
    XCTAssertEqual(BMAPFunction.notificationsByFblock, 2)
    XCTAssertEqual(BMAPFunction.authCodename, 12)
    XCTAssertEqual(BMAPFunction.authPlatform, 13)
  }

  func testProductNamePayloadParsing() {
    // [1.2] STATUS payload: flag byte + UTF-8 name ("Mathis' Headphones" capture)
    let payload: [UInt8] = [0x00] + Array("Mathis' Headphones".utf8)
    let name = String(bytes: Array(payload[1...]), encoding: .utf8)
    XCTAssertEqual(name, "Mathis' Headphones")
  }

  func testStandbyTimerSweepValue() {
    // Sweep capture: [1.4] STATUS 28 = 40 (auto-off minutes)
    XCTAssertEqual(0x28, 40)
  }

  func testMetadataNewFieldsDefaultNil() {
    let meta = DeviceMetadata()
    XCTAssertNil(meta.deviceName)
    XCTAssertNil(meta.reportedCodename)
    XCTAssertNil(meta.platformName)
    XCTAssertNil(meta.standbyTimer)
  }

  // MARK: - Paired Device Connect

  func testBuildConnectPayload() {
    XCTAssertEqual(
      buildConnectPayload(mac: "64:31:58:02:5e:03"),
      [0x00, 0x64, 0x31, 0x58, 0x02, 0x5E, 0x03])
    XCTAssertNil(buildConnectPayload(mac: "not-a-mac"))
    XCTAssertNil(buildConnectPayload(mac: "64:31:58:02:5e"))
    XCTAssertNil(buildConnectPayload(mac: "64:31:xx:02:5e:03"))
  }

  func testConnectPacketBytes() {
    let payload = buildConnectPayload(mac: "64:31:58:02:5e:03")!
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.deviceManagement, funcID: BMAPFunction.connectDevice,
      op: BMAPOperator.start.rawValue, payload: payload)
    XCTAssertEqual(pkt, [0x04, 0x01, 0x05, 0x07, 0x00, 0x64, 0x31, 0x58, 0x02, 0x5E, 0x03])
  }

  // MARK: - Standby Timer

  func testStandbyTimerPacketBytes() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.standbyTimer,
      op: BMAPOperator.setGet.rawValue, payload: [40])
    XCTAssertEqual(pkt, [0x01, 0x04, 0x02, 0x01, 0x28])
  }

  // MARK: - Product GUID

  func testFormatGuid() {
    let bytes: [UInt8] = [
      0x19, 0x23, 0x1E, 0x38, 0x4F, 0x96, 0x5D, 0xC8,
      0xE5, 0x99, 0x02, 0xD1, 0xD5, 0xB6, 0x9A, 0xDE,
    ]
    XCTAssertEqual(formatGuid(bytes), "19231e38-4f96-5dc8-e599-02d1d5b69ade")
    XCTAssertNil(formatGuid([0x01, 0x02]))
  }

  func testProductGuidConstant() {
    XCTAssertEqual(BMAPFunction.productGuid, 12)
  }

  // MARK: - Motion Auto-off

  // MARK: - CNC Scale (raw 0 = max ANC, Bose voice/app scale 10 = max ANC)

  func testCncScaleConversion() {
    XCTAssertEqual(cncDisplayLevel(raw: 0), 10)  // Quiet, voice says "ten"
    XCTAssertEqual(cncDisplayLevel(raw: 10), 0)  // Aware, voice says "zero"
    XCTAssertEqual(cncDisplayLevel(raw: 3), 7)
    XCTAssertEqual(cncRawLevel(displayed: 10), 0)
    XCTAssertEqual(cncRawLevel(displayed: 0), 10)
    XCTAssertEqual(cncRawLevel(displayed: 7), 3)
    // round-trip
    for raw: UInt8 in 0...10 {
      XCTAssertEqual(cncRawLevel(displayed: cncDisplayLevel(raw: raw)), raw)
    }
  }
  func testMotionAutoOffConstant() {
    XCTAssertEqual(BMAPFunction.motionAutoOff, 20)
  }

  func testMotionAutoOffGetPacket() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.motionAutoOff,
      op: BMAPOperator.get.rawValue)
    XCTAssertEqual(pkt, [0x01, 0x14, 0x01, 0x00])
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
