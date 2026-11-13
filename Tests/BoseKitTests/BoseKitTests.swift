import Testing

@testable import BoseKit

@Suite("BoseKit Tests")
struct BoseKitTests {

  // MARK: - BMAP Packet Tests

  @Test func packetSerialization() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cnc,
      op: BMAPOperator.setGet.rawValue, payload: [0x0A, 0x01])
    #expect(pkt == [0x01, 0x05, 0x02, 0x02, 0x0A, 0x01])
  }

  @Test func packetParsingValid() throws {
    let rawBytes: [UInt8] = [0x01, 0x07, 0x03, 0x04, 0xF6, 0x0A, 0x00, 0x00]
    let parsed = try #require(BMAPPacket.parse(rawBytes))
    #expect(parsed.functionBlock == 1)
    #expect(parsed.functionID == 7)
    #expect(parsed.operator == .status)
    #expect(parsed.payload == [0xF6, 0x0A, 0x00, 0x00])
  }

  @Test func packetParsingTruncated() {
    // Claims len 5, only 2 payload bytes
    let truncated: [UInt8] = [0x01, 0x07, 0x03, 0x05, 0x01, 0x02]
    #expect(BMAPPacket.parse(truncated) == nil)
  }

  // MARK: - CNC & Favorites Tests

  @Test func cncModeMapping() {
    #expect(NoiseMode.quiet.rawValue == 0)
    #expect(NoiseMode.aware.rawValue == 1)
    #expect(NoiseMode.quiet.label == "Quiet")
    #expect(NoiseMode.aware.label == "Aware")
    #expect(NoiseMode.quiet.symbolName == "waveform.slash")
    #expect(NoiseMode.aware.symbolName == "ear")
  }

  @Test func cncFavoritesDefault() {
    let favs = CncFavorites()
    #expect(favs.activeIndex == 0)
    #expect(favs.preset0 == 0)
    #expect(favs.preset1 == 5)
    #expect(favs.preset2 == 10)
    #expect(favs.level(for: 0) == 0)
    #expect(favs.level(for: 1) == 5)
    #expect(favs.level(for: 2) == 10)
  }

  @Test func cncFavoritesCustom() {
    let favs = CncFavorites(activeIndex: 2, preset0: 2, preset1: 6, preset2: 10)
    #expect(favs.activeIndex == 2)
    #expect(favs.level(for: 1) == 6)
  }

  // MARK: - Equalizer Tests

  @Test func equalizerClamping() {
    let eq = EqualizerSettings(bass: 15, mid: -20, treble: 5)
    #expect(eq.bass == 10)
    #expect(eq.mid == -10)
    #expect(eq.treble == 5)
  }

  @Test func equalizerSignedBytes() {
    // -10 dB in two's complement Int8 is 0xF6
    let minByte = UInt8(bitPattern: Int8(-10))
    #expect(minByte == 0xF6)

    // +10 dB in Int8 is 0x0A
    let maxByte = UInt8(bitPattern: Int8(10))
    #expect(maxByte == 0x0A)
  }

  // MARK: - Volume Tests

  @Test(arguments: [
    (current: UInt8(0), max: UInt8(16), expected: 0),
    (current: UInt8(8), max: UInt8(16), expected: 50),
    (current: UInt8(16), max: UInt8(16), expected: 100),
    (current: UInt8(6), max: UInt8(16), expected: 38),
  ])
  func volumePercentage(current: UInt8, max: UInt8, expected: Int) {
    #expect(VolumeInfo(current: current, max: max).percentage == expected)
  }

  // MARK: - Touch Shortcuts Tests

  @Test func shortcutActions() {
    #expect(ShortcutAction.batteryLevel.rawValue == 3)
    #expect(ShortcutAction.spotifyTap.rawValue == 16)
    #expect(ShortcutAction.wakeWord.rawValue == 7)

    #expect(ShortcutAction.batteryLevel.label == "Read Battery Level")
    #expect(ShortcutAction.spotifyTap.label == "Spotify Tap")
    #expect(ShortcutAction.wakeWord.label == "Enable/Disable Wake Word")
  }

  // MARK: - Notifications & Informative Blocks

  @Test func notificationsEnablePacket() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.notification, funcID: BMAPFunction.notificationsByFblock,
      op: BMAPOperator.setGet.rawValue, payload: [0x01, 0x00, 0x05, 0x02, 0x37])
    #expect(pkt == [0x09, 0x02, 0x02, 0x05, 0x01, 0x00, 0x05, 0x02, 0x37])
  }

  @Test func newFunctionConstants() {
    #expect(BMAPFunctionBlock.notification == 9)
    #expect(BMAPFunctionBlock.authentication == 18)
    #expect(BMAPFunction.standbyTimer == 4)
    #expect(BMAPFunction.notificationsByFblock == 2)
    #expect(BMAPFunction.authCodename == 12)
    #expect(BMAPFunction.authPlatform == 13)
  }

  @Test func productNamePayloadParsing() {
    // [1.2] STATUS payload: flag byte + UTF-8 name ("Mathis' Headphones" capture)
    let payload: [UInt8] = [0x00] + Array("Mathis' Headphones".utf8)
    let name = String(bytes: Array(payload[1...]), encoding: .utf8)
    #expect(name == "Mathis' Headphones")
  }

  @Test func standbyTimerSweepValue() {
    // Sweep capture: [1.4] STATUS 28 = 40 (auto-off minutes)
    #expect(0x28 == 40)
  }

  @Test func metadataNewFieldsDefaultNil() {
    let meta = DeviceMetadata()
    #expect(meta.deviceName == nil)
    #expect(meta.reportedCodename == nil)
    #expect(meta.platformName == nil)
    #expect(meta.standbyTimer == nil)
  }

  // MARK: - Paired Device Connect

  @Test func buildConnectPayloadValidation() {
    #expect(
      buildConnectPayload(mac: "64:31:58:02:5e:03")
        == [0x00, 0x64, 0x31, 0x58, 0x02, 0x5E, 0x03])
    #expect(buildConnectPayload(mac: "not-a-mac") == nil)
    #expect(buildConnectPayload(mac: "64:31:58:02:5e") == nil)
    #expect(buildConnectPayload(mac: "64:31:xx:02:5e:03") == nil)
  }

  @Test func connectPacketBytes() throws {
    let payload = try #require(buildConnectPayload(mac: "64:31:58:02:5e:03"))
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.deviceManagement, funcID: BMAPFunction.connectDevice,
      op: BMAPOperator.start.rawValue, payload: payload)
    #expect(pkt == [0x04, 0x01, 0x05, 0x07, 0x00, 0x64, 0x31, 0x58, 0x02, 0x5E, 0x03])
  }

  // MARK: - Standby Timer

  @Test func standbyTimerPacketBytes() {
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.standbyTimer,
      op: BMAPOperator.setGet.rawValue, payload: [40])
    #expect(pkt == [0x01, 0x04, 0x02, 0x01, 0x28])
  }

  // MARK: - Product GUID

  @Test func formatGuidFormatting() {
    let bytes: [UInt8] = [
      0x19, 0x23, 0x1E, 0x38, 0x4F, 0x96, 0x5D, 0xC8,
      0xE5, 0x99, 0x02, 0xD1, 0xD5, 0xB6, 0x9A, 0xDE,
    ]
    #expect(formatGuid(bytes) == "19231e38-4f96-5dc8-e599-02d1d5b69ade")
    #expect(formatGuid([0x01, 0x02]) == nil)
  }

  @Test func productGuidConstant() {
    #expect(BMAPFunction.productGuid == 12)
  }

  // MARK: - CNC Scale (raw 0 = max ANC, Bose voice/app scale 10 = max ANC)

  @Test func cncScaleConversion() {
    #expect(cncDisplayLevel(raw: 0) == 10)  // Quiet, voice says "ten"
    #expect(cncDisplayLevel(raw: 10) == 0)  // Aware, voice says "zero"
    #expect(cncDisplayLevel(raw: 3) == 7)
    #expect(cncRawLevel(displayed: 10) == 0)
    #expect(cncRawLevel(displayed: 0) == 10)
    #expect(cncRawLevel(displayed: 7) == 3)
    for raw: UInt8 in 0...10 {
      #expect(cncRawLevel(displayed: cncDisplayLevel(raw: raw)) == raw)
    }
  }

  @Test func motionAutoOffConstantAndGetPacket() {
    #expect(BMAPFunction.motionAutoOff == 20)
    let pkt = makeBMAPPacket(
      fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.motionAutoOff,
      op: BMAPOperator.get.rawValue)
    #expect(pkt == [0x01, 0x14, 0x01, 0x00])
  }

  // MARK: - Device Catalog Tests

  @Test func catalogProfiles() throws {
    let nc700 = try #require(DeviceCatalog.profile(forProductID: 0x4024))
    #expect(nc700.codename == "goodyear")
    #expect(nc700.defaultChannelID == 9)
    #expect(nc700.usesDirectCNC)

    let ultraHP = try #require(DeviceCatalog.profile(forProductID: 0x4060))
    #expect(ultraHP.codename == "wolverine")
    #expect(ultraHP.defaultChannelID == 2)
    #expect(!ultraHP.usesDirectCNC)

    let ultraEarbuds = try #require(DeviceCatalog.profile(forProductID: 0x4062))
    #expect(ultraEarbuds.defaultChannelID == 2)
  }

  // MARK: - Connected Device & Snapshot Tests

  @Test func connectedDeviceModel() {
    let dev = ConnectedDevice(
      macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", isConnected: true, isLocalHost: false,
      isActiveAudioSource: true)
    #expect(dev.macAddress == "AA:BB:CC:DD:EE:FF")
    #expect(dev.name == "Phone")
    #expect(dev.isConnected)
    #expect(!dev.isLocalHost)
    #expect(dev.isActiveAudioSource)
  }

  @MainActor
  @Test func deviceAppliesStateWithoutTransport() {
    let device = BoseDevice(transport: nil)
    #expect(!device.isConnected)
    device.apply(
      BoseStateSnapshot(
        isConnected: true,
        deviceName: "Test NC 700",
        usesDirectCNC: true,
        batteryInfo: BatteryInfo(single: 85),
        cncLevel: 3,
        volumeInfo: VolumeInfo(current: 12, max: 16)
      ))
    #expect(device.isConnected)
    #expect(device.deviceName == "Test NC 700")
    #expect(device.usesDirectCNC)
    #expect(device.batteryInfo.single == 85)
    #expect(device.cncLevel == 3)
    #expect(device.volumeInfo.current == 12)
  }
}
