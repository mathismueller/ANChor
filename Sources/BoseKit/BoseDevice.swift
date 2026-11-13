import Foundation
@preconcurrency import IOBluetooth
import os

/// Snapshot of device state produced on the Bluetooth thread and applied on `@MainActor`.
struct BoseStateSnapshot: Sendable {
  var isConnected: Bool?
  var deviceName: String?
  var usesDirectCNC: Bool?
  var hasEqualizer: Bool?
  var batteryInfo: BatteryInfo?
  var currentMode: NoiseMode??
  var cncLevel: UInt8?
  var equalizer: EqualizerSettings?
  var metadata: DeviceMetadata?
  var sidetone: SidetoneLevel?
  var voicePromptsEnabled: Bool?
  var multipointEnabled: Bool?
  var motionAutoOffEnabled: Bool?
  var shortcutAction: ShortcutAction?
  var cncFavorites: CncFavorites?
  var secondDevice: ConnectedDevice??
  var localDevice: ConnectedDevice??
  var pairedDevices: [ConnectedDevice]?
  var activeSourceMac: String??
  var volumeInfo: VolumeInfo?
}

/// Abstraction over the Bluetooth worker so unit tests can instantiate `BoseDevice`
/// without spawning background threads or registering `IOBluetooth` notifications.
protocol BoseTransport: AnyObject, Sendable {
  var onSnapshot: (@Sendable (BoseStateSnapshot) -> Void)? { get set }
  func start()
  func connect()
  func disconnect()
  func refreshState()
  func setMode(_ mode: NoiseMode)
  func setCNCLevel(_ step: UInt8)
  func setEqualizerBand(id: UInt8, rawByte: UInt8)
  func setSidetone(_ level: SidetoneLevel)
  func setVoicePrompts(enabled: Bool)
  func setStandbyTimer(_ minutes: UInt8)
  func setMultipoint(enabled: Bool)
  func setShortcutAction(_ action: ShortcutAction)
  func setCncFavorites(activeIndex: UInt8, preset0: UInt8, preset1: UInt8, preset2: UInt8)
  func sendRemotePlay()
  func sendRemotePause()
  func connectPairedDevice(payload: [UInt8])
  func setVolume(_ level: UInt8)
}

/// High-level interface to a connected Bose Bluetooth headphone or earbud.
@MainActor
public final class BoseDevice: NSObject {
  public static let shared = BoseDevice()

  // MARK: - Public State

  public private(set) var isConnected: Bool = false
  public private(set) var deviceName: String = "Bose Device"
  public private(set) var batteryInfo: BatteryInfo = BatteryInfo()
  public private(set) var currentMode: NoiseMode? = .quiet
  public private(set) var cncLevel: UInt8 = 0
  public private(set) var equalizer: EqualizerSettings = EqualizerSettings()
  public private(set) var hasEqualizer: Bool = true
  public private(set) var usesDirectCNC: Bool = false
  public private(set) var metadata: DeviceMetadata = DeviceMetadata()
  public private(set) var sidetone: SidetoneLevel = .medium
  public private(set) var voicePromptsEnabled: Bool = true
  public private(set) var multipointEnabled: Bool = false
  public private(set) var motionAutoOffEnabled: Bool = true
  public private(set) var shortcutAction: ShortcutAction = .batteryLevel
  public private(set) var cncFavorites: CncFavorites = CncFavorites()
  public private(set) var secondDevice: ConnectedDevice? = nil
  public private(set) var localDevice: ConnectedDevice? = nil
  public private(set) var pairedDevices: [ConnectedDevice] = []
  public private(set) var activeSourceMac: String? = nil
  public private(set) var isRemotePlaying: Bool = false
  public private(set) var volumeInfo: VolumeInfo = VolumeInfo()

  public var onUpdate: (() -> Void)?

  private let transport: (any BoseTransport)?

  public convenience override init() {
    self.init(transport: BTWorker(), startTransport: true)
  }

  init(transport: (any BoseTransport)?, startTransport: Bool = false) {
    self.transport = transport
    super.init()
    transport?.onSnapshot = { [weak self] snapshot in
      Task { @MainActor [weak self] in
        self?.apply(snapshot)
      }
    }
    if startTransport {
      transport?.start()
    }
  }

  func apply(_ s: BoseStateSnapshot) {
    if let v = s.isConnected { isConnected = v }
    if let v = s.deviceName { deviceName = v }
    if let v = s.usesDirectCNC { usesDirectCNC = v }
    if let v = s.hasEqualizer { hasEqualizer = v }
    if let v = s.batteryInfo { batteryInfo = v }
    if let v = s.currentMode { currentMode = v }
    if let v = s.cncLevel { cncLevel = v }
    if let v = s.equalizer { equalizer = v }
    if let v = s.metadata { metadata = v }
    if let v = s.sidetone { sidetone = v }
    if let v = s.voicePromptsEnabled { voicePromptsEnabled = v }
    if let v = s.multipointEnabled { multipointEnabled = v }
    if let v = s.motionAutoOffEnabled { motionAutoOffEnabled = v }
    if let v = s.shortcutAction { shortcutAction = v }
    if let v = s.cncFavorites { cncFavorites = v }
    if let v = s.secondDevice { secondDevice = v }
    if let v = s.localDevice { localDevice = v }
    if let v = s.pairedDevices { pairedDevices = v }
    if let v = s.activeSourceMac { activeSourceMac = v }
    if let v = s.volumeInfo { volumeInfo = v }
    onUpdate?()
  }

  public nonisolated func log(_ msg: String, level: OSLogType = .info) {
    AppLog.device.log(level: level, "\(msg, privacy: .public)")
  }

  #if DEBUG
    public func setDirectCNCForTesting(_ direct: Bool) {
      usesDirectCNC = direct
    }

    public func setConnectedForTesting(_ connected: Bool) {
      isConnected = connected
    }
  #endif

  public func connectAsync() {
    transport?.connect()
  }

  public func disconnect() {
    isConnected = false
    onUpdate?()
    transport?.disconnect()
  }

  public func refreshState() {
    transport?.refreshState()
  }

  // MARK: - Control Actions

  public func setMode(_ mode: NoiseMode) {
    currentMode = mode
    onUpdate?()
    transport?.setMode(mode)
  }

  public func setCNCLevel(_ step: UInt8) {
    let clamped = max(0, min(10, step))
    cncLevel = clamped
    if clamped == 0 {
      currentMode = .quiet
    } else if clamped == 10 {
      currentMode = .aware
    } else {
      currentMode = nil
    }
    onUpdate?()
    transport?.setCNCLevel(clamped)
  }

  public func setEqualizerBand(id: UInt8, level: Int) {
    let clamped = max(-10, min(10, level))
    switch id {
    case EqBand.bassId: equalizer.bass = clamped
    case EqBand.midId: equalizer.mid = clamped
    case EqBand.trebleId: equalizer.treble = clamped
    default: break
    }
    onUpdate?()
    let rawByte = UInt8(clamped < 0 ? clamped + 256 : clamped)
    transport?.setEqualizerBand(id: id, rawByte: rawByte)
  }

  public func setSidetone(_ level: SidetoneLevel) {
    sidetone = level
    onUpdate?()
    transport?.setSidetone(level)
  }

  public func setVoicePrompts(enabled: Bool) {
    voicePromptsEnabled = enabled
    onUpdate?()
    transport?.setVoicePrompts(enabled: enabled)
  }

  /// Sets the auto-off timer (minutes) via SETGET [1.4]. 0x00 = Never.
  /// Verified on hardware: SETGET is accepted (STATUS echo), unlike SET/START.
  public func setStandbyTimer(_ minutes: UInt8) {
    metadata.standbyTimer = minutes
    onUpdate?()
    transport?.setStandbyTimer(minutes)
  }

  public func setMultipoint(enabled: Bool) {
    multipointEnabled = enabled
    onUpdate?()
    transport?.setMultipoint(enabled: enabled)
  }

  public func setShortcutAction(_ action: ShortcutAction) {
    shortcutAction = action
    onUpdate?()
    transport?.setShortcutAction(action)
  }

  public func setCncFavorites(preset0: Int, preset1: Int, preset2: Int) {
    let p0 = UInt8(clamping: preset0)
    let p1 = UInt8(clamping: preset1)
    let p2 = UInt8(clamping: preset2)
    let curIdx = UInt8(cncFavorites.activeIndex)
    cncFavorites.preset0 = Int(p0)
    cncFavorites.preset1 = Int(p1)
    cncFavorites.preset2 = Int(p2)
    onUpdate?()
    transport?.setCncFavorites(activeIndex: curIdx, preset0: p0, preset1: p1, preset2: p2)
  }

  public func selectCncFavorite(index: Int) {
    let idx = UInt8(index % 3)
    let p0 = UInt8(cncFavorites.preset0)
    let p1 = UInt8(cncFavorites.preset1)
    let p2 = UInt8(cncFavorites.preset2)
    cncFavorites.activeIndex = Int(idx)
    let targetLevel = idx == 0 ? p0 : (idx == 1 ? p1 : p2)
    cncLevel = targetLevel
    if targetLevel == 0 {
      currentMode = .quiet
    } else if targetLevel == 10 {
      currentMode = .aware
    } else {
      currentMode = nil
    }
    onUpdate?()
    transport?.setCncFavorites(activeIndex: idx, preset0: p0, preset1: p1, preset2: p2)
  }

  // MARK: - Remote Media Transport Controls

  public func sendRemotePlay() {
    isRemotePlaying = true
    onUpdate?()
    transport?.sendRemotePlay()
  }

  public func sendRemotePause() {
    isRemotePlaying = false
    onUpdate?()
    transport?.sendRemotePause()
  }

  public func toggleRemotePlayback() {
    if isRemotePlaying {
      sendRemotePause()
    } else {
      sendRemotePlay()
    }
  }

  /// Asks the headphones to connect (and route audio) to a paired device.
  /// Async: the ack is PROCESSING; success is silent, failure arrives later
  /// as an ERROR. The 3s poll picks up the result.
  public func connectPairedDevice(mac: String) {
    guard let payload = buildConnectPayload(mac: mac) else {
      AppLog.device.error("connectPairedDevice: malformed MAC \(mac, privacy: .public)")
      return
    }
    AppLog.device.info("connectPairedDevice → \(mac, privacy: .public)")
    transport?.connectPairedDevice(payload: payload)
  }

  // MARK: - Remote Volume Controls

  public func setVolume(_ level: UInt8) {
    let clamped = min(max(level, 0), volumeInfo.max)
    volumeInfo.current = clamped
    onUpdate?()
    transport?.setVolume(clamped)
  }

  public func volumeUp() {
    if volumeInfo.current < volumeInfo.max {
      setVolume(volumeInfo.current + 1)
    }
  }

  public func volumeDown() {
    if volumeInfo.current > 0 {
      setVolume(volumeInfo.current - 1)
    }
  }
}

// MARK: - Bluetooth Worker (dedicated RunLoop thread)

/// Owns all `IOBluetooth` channel state and timers exclusively on `btThread`.
private final class BTWorker: NSObject, BoseTransport, IOBluetoothRFCOMMChannelDelegate,
  @unchecked Sendable
{
  private var channel: IOBluetoothRFCOMMChannel?
  private var expectedFBlock: UInt8?
  private var expectedFuncID: UInt8?
  private var responsePacket: BMAPPacket?
  private var responseReceived = false
  private var btThread: Thread?
  private var btRunLoop: RunLoop?
  private let ready = DispatchSemaphore(value: 0)
  private var reconnectTimer: Timer?
  private var pollTimer: Timer?
  private var connectNotification: IOBluetoothUserNotification?
  private var isConnecting = false

  private var isConnected = false
  private var deviceName = "Bose Device"
  private var usesDirectCNC = false
  private var hasEqualizer = true
  private var metadata = DeviceMetadata()
  private var currentMode: NoiseMode? = .quiet
  private var cncLevel: UInt8 = 0
  private var equalizer = EqualizerSettings()
  private var sidetone: SidetoneLevel = .medium
  private var voicePromptsEnabled = true
  private var multipointEnabled = false
  private var motionAutoOffEnabled = true
  private var shortcutAction: ShortcutAction = .batteryLevel
  private var cncFavorites = CncFavorites()
  private var volumeInfo = VolumeInfo()
  private var activeSourceMac: String? = nil
  private var localMacAddressString: String? = nil
  private var knownDeviceNames: [String: String] = [:]
  private var nameLookupAttempted: Set<String> = []

  private var targetChannelID: BluetoothRFCOMMChannelID = 2
  private var lastModeChangeTime: Date = .distantPast
  private var voiceLanguageId: UInt8 = 1

  var onSnapshot: (@Sendable (BoseStateSnapshot) -> Void)?

  deinit {
    connectNotification?.unregister()
  }

  func start() {
    startBTThread()
    registerForConnectNotifications()
  }

  func connect() { enqueue(#selector(doConnect)) }
  func disconnect() { enqueue(#selector(doDisconnect)) }
  func refreshState() { enqueue(#selector(doRefreshState)) }
  func setMode(_ mode: NoiseMode) {
    enqueue(#selector(doSetMode(_:)), with: NSNumber(value: mode.rawValue))
  }
  func setCNCLevel(_ step: UInt8) {
    enqueue(#selector(doSetCNC(_:)), with: NSNumber(value: step))
  }
  func setEqualizerBand(id: UInt8, rawByte: UInt8) {
    enqueue(#selector(doSetEQBand(_:)), with: [id, rawByte] as NSArray)
  }
  func setSidetone(_ level: SidetoneLevel) {
    enqueue(#selector(doSetSidetone(_:)), with: NSNumber(value: level.rawValue))
  }
  func setVoicePrompts(enabled: Bool) {
    enqueue(#selector(doSetVoicePrompts(_:)), with: NSNumber(value: enabled))
  }
  func setStandbyTimer(_ minutes: UInt8) {
    enqueue(#selector(doSetStandbyTimer(_:)), with: NSNumber(value: minutes))
  }
  func setMultipoint(enabled: Bool) {
    enqueue(#selector(doSetMultipoint(_:)), with: NSNumber(value: enabled))
  }
  func setShortcutAction(_ action: ShortcutAction) {
    enqueue(#selector(doSetShortcut(_:)), with: NSNumber(value: action.rawValue))
  }
  func setCncFavorites(activeIndex: UInt8, preset0: UInt8, preset1: UInt8, preset2: UInt8) {
    enqueue(
      #selector(doSetCncFavorites(_:)),
      with: [activeIndex, preset0, preset1, preset2] as NSArray)
  }
  func sendRemotePlay() { enqueue(#selector(doSendRemotePlay)) }
  func sendRemotePause() { enqueue(#selector(doSendRemotePause)) }
  func connectPairedDevice(payload: [UInt8]) {
    enqueue(#selector(doConnectPairedDevice(_:)), with: payload as NSArray)
  }
  func setVolume(_ level: UInt8) {
    enqueue(#selector(doSetVolume(_:)), with: NSNumber(value: level))
  }

  private func startBTThread() {
    let thread = Thread { [weak self] in
      self?.btRunLoop = RunLoop.current
      self?.ready.signal()
      let port = Port()
      RunLoop.current.add(port, forMode: .default)
      RunLoop.current.run()
    }
    thread.name = "BoseKit-BT"
    btThread = thread
    thread.start()
    ready.wait()
  }

  private func enqueue(_ selector: Selector, with arg: Any? = nil) {
    guard let thread = btThread else { return }
    perform(selector, on: thread, with: arg, waitUntilDone: false)
  }

  private func registerForConnectNotifications() {
    connectNotification = IOBluetoothDevice.register(
      forConnectNotifications: self,
      selector: #selector(handleDeviceConnectedNotification(_:from:))
    )
  }

  @objc private func handleDeviceConnectedNotification(
    _ notification: IOBluetoothUserNotification!, from device: IOBluetoothDevice!
  ) {
    guard let dev = device else { return }
    let name = dev.name ?? "unknown"
    AppLog.bluetooth.debug("Bluetooth device connected event from: \(name, privacy: .public)")
    enqueue(#selector(doConnectIfNeeded))
  }

  @objc private func doConnectIfNeeded() {
    if !isConnected && channel == nil && !isConnecting {
      doConnect()
    }
  }

  @objc func doConnect() {
    guard channel == nil, !isConnected, !isConnecting else { return }
    isConnecting = true
    defer { isConnecting = false }

    guard
      let discovered = BoseDiscovery.findDevice(log: {
        AppLog.device.debug("\($0, privacy: .public)")
      })
    else {
      AppLog.bluetooth.error("❌ No Bose device found")
      isConnected = false
      scheduleReconnectTimer()
      onSnapshot?(BoseStateSnapshot(isConnected: false))
      return
    }

    let dev = discovered.device
    targetChannelID = discovered.channelID
    usesDirectCNC = discovered.usesDirectCNC
    hasEqualizer = discovered.profile?.hasEqualizer ?? true

    metadata.modelName =
      discovered.profile?.name
      ?? (usesDirectCNC ? "Noise Cancelling Headphones 700" : "Bose Device")
    metadata.productID = discovered.profile?.productID ?? (usesDirectCNC ? 0x4024 : nil)

    AppLog.bluetooth.info(
      "Found: \(dev.name ?? "unknown", privacy: .public) [\(dev.addressString ?? "?", privacy: .public)] ch=\(self.targetChannelID) directCNC=\(self.usesDirectCNC)"
    )

    if !dev.isConnected() {
      AppLog.bluetooth.debug("openConnection...")
      _ = dev.openConnection(nil)
      let deadline = Date().addingTimeInterval(5.0)
      while !dev.isConnected() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      }
    }

    AppLog.bluetooth.info("Opening RFCOMM ch \(self.targetChannelID)...")
    var chan: IOBluetoothRFCOMMChannel? = nil
    let result = dev.openRFCOMMChannelSync(&chan, withChannelID: targetChannelID, delegate: self)
    AppLog.bluetooth.debug("RFCOMM result: \(result)")

    if result == kIOReturnSuccess, let c = chan {
      channel = c
      isConnected = true
      deviceName = dev.name ?? "Bose Device"
      AppLog.bluetooth.notice("✅ Connected to \(self.deviceName, privacy: .public)")
      stopReconnectTimer()

      if let addr = dev.addressString {
        let defaults = UserDefaults.standard
        defaults.set(addr, forKey: "lastBoseDeviceAddress")
        defaults.set(Int(targetChannelID), forKey: "lastBoseChannelID")
        defaults.set(usesDirectCNC, forKey: "lastBoseDirectCNC")
      }

      let drainEnd = Date().addingTimeInterval(0.05)
      while Date() < drainEnd {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }

      nameLookupAttempted = []
      fetchDeviceMetadata()
      doRefreshState()
      schedulePollTimer()
    } else {
      AppLog.bluetooth.error("❌ RFCOMM failed: \(result)")
      isConnected = false
      scheduleReconnectTimer()
      onSnapshot?(
        BoseStateSnapshot(
          isConnected: false,
          usesDirectCNC: usesDirectCNC,
          hasEqualizer: hasEqualizer,
          metadata: metadata
        ))
    }
  }

  @objc func doDisconnect() {
    stopPollTimer()
    stopReconnectTimer()
    _ = channel?.close()
    channel = nil
    isConnected = false
    onSnapshot?(BoseStateSnapshot(isConnected: false))
  }

  private func enableNotifications() {
    let payload: [UInt8] = [0x01, 0x00, 0x05, 0x02, 0x37]
    guard
      let pkt = query(
        BMAPFunctionBlock.notification, BMAPFunction.notificationsByFblock,
        op: .setGet, payload: payload, timeout: 2.0)
    else {
      AppLog.device.info("Notifications [9.2]: no reply, continuing with polling")
      return
    }
    if pkt.operator == .status {
      AppLog.device.info("Notifications [9.2]: subscribed")
    } else {
      AppLog.device.info(
        "Notifications [9.2]: refused (op=\(pkt.operator.rawValue)), continuing with polling")
    }
  }

  private func fetchDeviceMetadata() {
    enableNotifications()

    if let pkt = query(BMAPFunctionBlock.deviceInfo, BMAPFunction.firmwareVersion),
      pkt.operator == .status,
      let str = String(bytes: pkt.payload, encoding: .utf8)
    {
      metadata.firmwareVersion = str
      AppLog.device.info("Firmware: \(str, privacy: .public)")
    }

    if let pkt = query(BMAPFunctionBlock.deviceInfo, BMAPFunction.protocolVersion),
      pkt.operator == .status,
      let str = String(bytes: pkt.payload, encoding: .utf8)
    {
      metadata.protocolVersion = str
      AppLog.device.info("Protocol: BMAP \(str, privacy: .public)")
    }

    if let pkt = query(BMAPFunctionBlock.deviceInfo, BMAPFunction.serialNumber),
      pkt.operator == .status,
      let str = String(bytes: pkt.payload, encoding: .utf8)
    {
      metadata.serialNumber = str
      AppLog.device.info("Serial: \(str, privacy: .public)")
    }

    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.productName),
      pkt.operator == .status, pkt.payload.count >= 1,
      let str = String(bytes: Array(pkt.payload.dropFirst()), encoding: .utf8), !str.isEmpty
    {
      metadata.deviceName = str
      AppLog.device.info("Device name [1.2]: \(str, privacy: .public)")
    }

    if let pkt = query(BMAPFunctionBlock.deviceInfo, BMAPFunction.productGuid),
      pkt.operator == .status, pkt.payload.count >= 16,
      let guid = formatGuid(Array(pkt.payload.prefix(16)))
    {
      metadata.productGuid = guid
      AppLog.device.info("GUID [0.12]: \(guid, privacy: .public)")
    }

    if let pkt = query(BMAPFunctionBlock.authentication, BMAPFunction.authCodename),
      pkt.operator == .status,
      let str = String(bytes: pkt.payload, encoding: .utf8), !str.isEmpty
    {
      metadata.reportedCodename = str
      AppLog.device.info("Codename [18.12]: \(str, privacy: .public)")
    }

    if let pkt = query(BMAPFunctionBlock.authentication, BMAPFunction.authPlatform),
      pkt.operator == .status,
      let str = String(bytes: pkt.payload, encoding: .utf8), !str.isEmpty
    {
      metadata.platformName = str
      AppLog.device.info("Platform [18.13]: \(str, privacy: .public)")
    }
  }

  @objc func doRefreshState() {
    guard channel != nil else { return }

    var snapshot = BoseStateSnapshot(
      isConnected: isConnected,
      deviceName: deviceName,
      usesDirectCNC: usesDirectCNC,
      hasEqualizer: hasEqualizer
    )

    // 1. Noise Mode / CNC [1.5] or [31.3]
    if usesDirectCNC {
      if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.cnc),
        pkt.operator == .status, pkt.payload.count >= 2
      {
        let step = pkt.payload[1]
        cncLevel = step
        snapshot.cncLevel = step
        if Date().timeIntervalSince(lastModeChangeTime) >= 1.5 {
          currentMode = step == 0 ? .quiet : (step == 10 ? .aware : nil)
          snapshot.currentMode = .some(currentMode)
        }
        AppLog.device.debug(
          "CNC step \(step) -> \(self.currentMode?.label ?? "Level \(step)")")
      }
    } else {
      if let pkt = query(BMAPFunctionBlock.audioModes, BMAPFunction.currentMode),
        pkt.operator == .status, let first = pkt.payload.first,
        Date().timeIntervalSince(lastModeChangeTime) >= 1.5,
        let mode = NoiseMode(rawValue: first)
      {
        currentMode = mode
        snapshot.currentMode = .some(mode)
      }
    }

    // 2. Battery [2.2]
    if let pkt = query(BMAPFunctionBlock.battery, BMAPFunction.batteryLevel),
      pkt.operator == .status, !pkt.payload.isEmpty
    {
      let payload = pkt.payload
      if payload.count == 4 && payload[3] == 0 {
        snapshot.batteryInfo = BatteryInfo(single: Int(payload[0]))
      } else {
        var l: Int? = nil
        var r: Int? = nil
        var c: Int? = nil
        var i = 0
        while i + 3 < payload.count {
          let level = Int(payload[i])
          switch payload[i + 3] {
          case 1: l = level
          case 2: r = level
          case 3, 4: c = level
          default: break
          }
          i += 4
        }
        snapshot.batteryInfo = BatteryInfo(single: nil, left: l, right: r, caseLevel: c)
      }
    }

    // 3. Equalizer [1.7]
    if hasEqualizer {
      if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.equalizer),
        pkt.operator == .status
      {
        let payload = pkt.payload
        var b = equalizer.bass
        var m = equalizer.mid
        var t = equalizer.treble
        var i = 0
        while i + 3 < payload.count {
          let curRaw = payload[i + 2]
          let curVal = curRaw < 128 ? Int(curRaw) : Int(curRaw) - 256
          switch payload[i + 3] {
          case EqBand.bassId: b = curVal
          case EqBand.midId: m = curVal
          case EqBand.trebleId: t = curVal
          default: break
          }
          i += 4
        }
        equalizer = EqualizerSettings(bass: b, mid: m, treble: t)
        snapshot.equalizer = equalizer
      }
    }

    // 4. Sidetone [1.11]
    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.sidetone),
      pkt.operator == .status, pkt.payload.count >= 2,
      let lvl = SidetoneLevel(rawValue: pkt.payload[1])
    {
      sidetone = lvl
      snapshot.sidetone = lvl
    }

    // 5. Voice Prompts [1.3]
    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.voicePrompts),
      pkt.operator == .status, let first = pkt.payload.first
    {
      voicePromptsEnabled = ((first >> 5) & 1) == 1
      voiceLanguageId = first & 0x1F
      snapshot.voicePromptsEnabled = voicePromptsEnabled
    }

    // 6. Multipoint [1.10]
    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.multipoint),
      pkt.operator == .status, let first = pkt.payload.first
    {
      multipointEnabled = first != 0
      snapshot.multipointEnabled = multipointEnabled
    }

    // 6c. Motion Auto-off [1.20]
    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.motionAutoOff),
      pkt.operator == .status, let raw = pkt.payload.first
    {
      if (raw != 0) != motionAutoOffEnabled {
        motionAutoOffEnabled = raw != 0
        AppLog.device.info("Motion auto-off [1.20]: \(raw)")
      }
      snapshot.motionAutoOffEnabled = motionAutoOffEnabled
    }

    // 6b. Standby Timer [1.4]
    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.standbyTimer),
      pkt.operator == .status, let raw = pkt.payload.first
    {
      if metadata.standbyTimer != raw {
        metadata.standbyTimer = raw
        AppLog.device.info("Standby timer [1.4]: \(raw)")
      }
    }
    snapshot.metadata = metadata

    // 7. Shortcut Button [1.9]
    if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.buttons),
      pkt.operator == .status, pkt.payload.count >= 3,
      let act = ShortcutAction(rawValue: pkt.payload[2])
    {
      shortcutAction = act
      snapshot.shortcutAction = act
    }

    // 8. CNC Favorites [1.15]
    if usesDirectCNC {
      if let pkt = query(BMAPFunctionBlock.settings, BMAPFunction.cncFavorites),
        pkt.operator == .status, pkt.payload.count >= 4
      {
        cncFavorites = CncFavorites(
          activeIndex: Int(pkt.payload[0]), preset0: Int(pkt.payload[1]),
          preset1: Int(pkt.payload[2]), preset2: Int(pkt.payload[3]))
        snapshot.cncFavorites = cncFavorites
      }
    }

    // 9. Local MAC Address [4.9]
    if localMacAddressString == nil {
      if let pkt = query(BMAPFunctionBlock.deviceManagement, BMAPFunction.localMacAddress),
        pkt.operator == .status, pkt.payload.count >= 6
      {
        localMacAddressString = pkt.payload.prefix(6).map { String(format: "%02x", $0) }.joined(
          separator: ":")
      }
    }

    // 10. Active Audio Source [5.1]
    if let pkt = query(BMAPFunctionBlock.audioManagement, BMAPFunction.audioSource),
      pkt.operator == .status, pkt.payload.count >= 9
    {
      activeSourceMac = pkt.payload[3..<9].map { String(format: "%02x", $0) }.joined(
        separator: ":")
      snapshot.activeSourceMac = .some(activeSourceMac)
    }

    // 11. Connected Devices [4.4]
    if let pkt = query(BMAPFunctionBlock.deviceManagement, BMAPFunction.listDevices),
      pkt.operator == .status, pkt.payload.count >= 7
    {
      let connMask = pkt.payload[0]
      var offset = 1
      var slot = 0
      var foundSecond: ConnectedDevice? = nil
      var foundLocal: ConnectedDevice? = nil
      var all: [ConnectedDevice] = []
      while offset + 6 <= pkt.payload.count {
        let macBytes = Array(pkt.payload[offset..<(offset + 6)])
        let macStr = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        let isConn = (connMask & (1 << slot)) != 0
        let isLocal = (macStr == localMacAddressString)
        let isActive = (macStr == activeSourceMac)

        var devName =
          knownDeviceNames[macStr] ?? (isLocal ? "MacBook Pro" : "Bluetooth Device")
        let shouldLookup =
          isConn
          || (knownDeviceNames[macStr] == nil && !nameLookupAttempted.contains(macStr))
        if shouldLookup {
          if !isConn { nameLookupAttempted.insert(macStr) }
          if let namePkt = query(
            BMAPFunctionBlock.deviceManagement, BMAPFunction.peerDeviceInfo, payload: macBytes),
            namePkt.payload.count > 9,
            let str = String(bytes: Array(namePkt.payload[9...]), encoding: .utf8), !str.isEmpty
          {
            devName = str
            knownDeviceNames[macStr] = str
          }
        }

        let dev = ConnectedDevice(
          macAddress: macStr, name: devName, isConnected: isConn, isLocalHost: isLocal,
          isActiveAudioSource: isActive)
        all.append(dev)
        if isLocal {
          foundLocal = dev
        } else if isConn && foundSecond == nil {
          foundSecond = dev
        }

        offset += 6
        slot += 1
      }
      snapshot.pairedDevices = all
      snapshot.secondDevice = .some(foundSecond)
      snapshot.localDevice = .some(foundLocal)
    }

    // 12. Volume Level [5.5]
    if let pkt = query(BMAPFunctionBlock.audioManagement, BMAPFunction.volume),
      pkt.operator == .status, pkt.payload.count >= 2
    {
      volumeInfo = VolumeInfo(current: pkt.payload[1], max: pkt.payload[0])
      snapshot.volumeInfo = volumeInfo
    }

    onSnapshot?(snapshot)
  }

  // MARK: - Control Executors (btThread)

  @objc func doSetMode(_ num: NSNumber) {
    guard let mode = NoiseMode(rawValue: num.uint8Value) else { return }
    lastModeChangeTime = Date()
    currentMode = mode
    AppLog.device.info("setMode: \(mode.label, privacy: .public)")
    if usesDirectCNC {
      let step: UInt8 = (mode == .quiet) ? 0 : 10
      cncLevel = step
      sendRawPacket(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cnc,
          op: BMAPOperator.setGet.rawValue, payload: [step, 0x01]))
      AppLog.device.info("✅ CNC switched to \(step) (\(mode.label, privacy: .public))")
    } else {
      let pkt = query(
        BMAPFunctionBlock.audioModes, BMAPFunction.currentMode,
        op: .start, payload: [mode.rawValue, 0x00])
      if let pkt, pkt.operator == .result, !pkt.payload.isEmpty {
        AppLog.device.info("✅ Mode switched")
      } else {
        AppLog.device.error("❌ Mode switch failed")
      }
    }
    onSnapshot?(BoseStateSnapshot(currentMode: .some(currentMode), cncLevel: cncLevel))
  }

  @objc func doSetCNC(_ num: NSNumber) {
    let step = num.uint8Value
    lastModeChangeTime = Date()
    cncLevel = step
    AppLog.device.info("setCNCLevel: \(step)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cnc,
        op: BMAPOperator.setGet.rawValue, payload: [step, 0x01]))
  }

  @objc func doSetEQBand(_ args: NSArray) {
    guard args.count >= 2, let bandId = (args[0] as? NSNumber)?.uint8Value,
      let val = (args[1] as? NSNumber)?.uint8Value
    else { return }
    AppLog.device.info("setEQBand: band=\(bandId), val=\(val)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.equalizer,
        op: BMAPOperator.setGet.rawValue, payload: [val, bandId]))
  }

  @objc func doSetSidetone(_ num: NSNumber) {
    let val = num.uint8Value
    AppLog.device.info("setSidetone: \(val)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.sidetone,
        op: BMAPOperator.setGet.rawValue, payload: [0x01, val]))
  }

  @objc func doSetStandbyTimer(_ num: NSNumber) {
    let val = num.uint8Value
    AppLog.device.info("setStandbyTimer: \(val)")
    guard
      let pkt = query(
        BMAPFunctionBlock.settings, BMAPFunction.standbyTimer,
        op: .setGet, payload: [val], timeout: 2.0)
    else {
      AppLog.device.info("setStandbyTimer: no reply, will correct on refresh")
      return
    }
    AppLog.device.info("setStandbyTimer: reply op=\(pkt.operator.rawValue)")
  }

  @objc func doSetVoicePrompts(_ num: NSNumber) {
    let en = num.boolValue
    let payloadByte = (en ? 0x20 : 0x00) | (voiceLanguageId & 0x1F)
    AppLog.device.info("setVoicePrompts: enabled=\(en)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.voicePrompts,
        op: BMAPOperator.setGet.rawValue, payload: [payloadByte]))
  }

  @objc func doSetMultipoint(_ num: NSNumber) {
    let en = num.boolValue
    AppLog.device.info("setMultipoint: \(en)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.multipoint,
        op: BMAPOperator.setGet.rawValue, payload: [en ? 0x01 : 0x00]))
  }

  @objc func doSetShortcut(_ num: NSNumber) {
    let act = num.uint8Value
    AppLog.device.info("setShortcutAction: \(act)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.buttons,
        op: BMAPOperator.setGet.rawValue, payload: [0x80, 0x05, act]))
  }

  @objc func doSetCncFavorites(_ arr: NSArray) {
    let bytes = arr.compactMap { ($0 as? NSNumber)?.uint8Value }
    guard bytes.count == 4 else { return }
    lastModeChangeTime = Date()
    AppLog.device.info(
      "setCncFavorites: idx=\(bytes[0]) p0=\(bytes[1]) p1=\(bytes[2]) p2=\(bytes[3])")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cncFavorites,
        op: BMAPOperator.setGet.rawValue, payload: bytes))
  }

  @objc func doSendRemotePlay() {
    AppLog.device.info("sendRemotePlay")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.audioControl,
        op: BMAPOperator.start.rawValue, payload: [0x01]))
  }

  @objc func doSendRemotePause() {
    AppLog.device.info("sendRemotePause")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.audioControl,
        op: BMAPOperator.start.rawValue, payload: [0x02]))
  }

  @objc func doConnectPairedDevice(_ arr: NSArray) {
    let payload = arr.compactMap { ($0 as? NSNumber)?.uint8Value }
    guard
      let pkt = query(
        BMAPFunctionBlock.deviceManagement, BMAPFunction.connectDevice,
        op: .start, payload: payload, timeout: 5.0)
    else {
      AppLog.device.error("connectPairedDevice: no reply (will retry via poll)")
      return
    }
    AppLog.device.info("connectPairedDevice: reply op=\(pkt.operator.rawValue)")
    onSnapshot?(BoseStateSnapshot())
  }

  @objc func doSetVolume(_ num: NSNumber) {
    let lvl = num.uint8Value
    AppLog.device.info("setVolume: \(lvl)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.volume,
        op: BMAPOperator.setGet.rawValue, payload: [lvl]))
  }

  private func sendRawPacket(_ packet: [UInt8]) {
    guard let channel = channel else { return }
    var pkt = packet
    _ = pkt.withUnsafeMutableBufferPointer { buf in
      channel.writeSync(buf.baseAddress!, length: UInt16(buf.count))
    }
  }

  private func query(
    _ fblock: UInt8, _ funcID: UInt8, op: BMAPOperator = .get, payload: [UInt8] = [],
    timeout: TimeInterval = 1.0
  ) -> BMAPPacket? {
    guard let channel = channel else { return nil }
    expectedFBlock = fblock
    expectedFuncID = funcID
    responsePacket = nil
    responseReceived = false
    defer {
      expectedFBlock = nil
      expectedFuncID = nil
    }

    var pkt = BMAPPacket(functionBlock: fblock, functionID: funcID, operator: op, payload: payload)
      .rawBytes
    let writeOK = pkt.withUnsafeMutableBufferPointer { buf -> Bool in
      channel.writeSync(buf.baseAddress!, length: UInt16(buf.count)) == kIOReturnSuccess
    }
    guard writeOK else {
      AppLog.protocol.error("BMAP write failed")
      return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && !responseReceived {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return responseReceived ? responsePacket : nil
  }

  // MARK: - IOBluetoothRFCOMMChannelDelegate

  func rfcommChannelData(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int
  ) {
    let bytes = Array(
      UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: len))
    AppLog.protocol.debug(
      "RX(\(len, privacy: .public)): \(bytes.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)"
    )

    guard let packet = BMAPPacket.parse(bytes) else { return }

    var snapshot: BoseStateSnapshot?
    if packet.operator == .status {
      switch (packet.functionBlock, packet.functionID) {
      case (BMAPFunctionBlock.audioModes, BMAPFunction.currentMode):
        if let raw = packet.payload.first, let mode = NoiseMode(rawValue: raw),
          mode != currentMode
        {
          AppLog.device.info("📡 Unsolicited mode change: \(mode.label, privacy: .public)")
          currentMode = mode
          snapshot = snapshot ?? BoseStateSnapshot()
          snapshot?.currentMode = .some(mode)
        }

      case (BMAPFunctionBlock.settings, BMAPFunction.cnc) where packet.payload.count >= 2:
        let step = packet.payload[1]
        let stepChanged = (step != cncLevel)
        cncLevel = step
        if Date().timeIntervalSince(lastModeChangeTime) >= 1.5 {
          let newMode: NoiseMode? = step == 0 ? .quiet : (step == 10 ? .aware : nil)
          if stepChanged || newMode != currentMode {
            AppLog.device.info(
              "📡 CNC change: step \(step) -> \(newMode?.label ?? "Level \(step)", privacy: .public)"
            )
            currentMode = newMode
            snapshot = snapshot ?? BoseStateSnapshot()
            snapshot?.cncLevel = step
            snapshot?.currentMode = .some(newMode)
          }
        }

      case (BMAPFunctionBlock.settings, BMAPFunction.cncFavorites) where packet.payload.count >= 4:
        let newFav = CncFavorites(
          activeIndex: Int(packet.payload[0]), preset0: Int(packet.payload[1]),
          preset1: Int(packet.payload[2]), preset2: Int(packet.payload[3]))
        if newFav != cncFavorites {
          AppLog.device.info(
            "📡 CNC favorites change: active=\(newFav.activeIndex) [\(newFav.preset0), \(newFav.preset1), \(newFav.preset2)]"
          )
          cncFavorites = newFav
          snapshot = snapshot ?? BoseStateSnapshot()
          snapshot?.cncFavorites = newFav
        }

      case (BMAPFunctionBlock.settings, BMAPFunction.buttons) where packet.payload.count >= 3:
        if let act = ShortcutAction(rawValue: packet.payload[2]), act != shortcutAction {
          AppLog.device.info("📡 Button shortcut confirmed: \(act.label, privacy: .public)")
          shortcutAction = act
          snapshot = snapshot ?? BoseStateSnapshot()
          snapshot?.shortcutAction = act
        }

      case (BMAPFunctionBlock.audioManagement, BMAPFunction.audioSource)
      where packet.payload.count >= 9:
        let newMac = packet.payload[3..<9].map { String(format: "%02x", $0) }.joined(separator: ":")
        if newMac != activeSourceMac {
          activeSourceMac = newMac
          AppLog.device.info("📡 Active audio source change: \(newMac, privacy: .public)")
          snapshot = snapshot ?? BoseStateSnapshot()
          snapshot?.activeSourceMac = .some(newMac)
        }

      case (BMAPFunctionBlock.audioManagement, BMAPFunction.volume) where packet.payload.count >= 2:
        let newVol = VolumeInfo(current: packet.payload[1], max: packet.payload[0])
        if newVol != volumeInfo {
          volumeInfo = newVol
          AppLog.device.info(
            "📡 Volume change: \(newVol.current)/\(newVol.max) (\(newVol.percentage)%)")
          snapshot = snapshot ?? BoseStateSnapshot()
          snapshot?.volumeInfo = newVol
        }

      default:
        break
      }
    }

    if let snapshot {
      onSnapshot?(snapshot)
    }

    if expectedFBlock == packet.functionBlock && expectedFuncID == packet.functionID {
      responsePacket = packet
      responseReceived = true
    }
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    AppLog.bluetooth.notice("RFCOMM channel closed")
    channel = nil
    isConnected = false
    stopPollTimer()
    scheduleReconnectTimer()
    onSnapshot?(BoseStateSnapshot(isConnected: false))
  }

  // MARK: - Timers (btThread only)

  private func scheduleReconnectTimer() {
    stopReconnectTimer()
    reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      guard let self else { return }
      if self.channel == nil {
        AppLog.bluetooth.info("Auto-reconnect attempt...")
        self.doConnect()
      }
      if self.channel != nil {
        self.stopReconnectTimer()
      }
    }
  }

  private func stopReconnectTimer() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
  }

  private func schedulePollTimer() {
    stopPollTimer()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
      guard let self, self.channel != nil else { return }
      self.doRefreshState()
    }
  }

  private func stopPollTimer() {
    pollTimer?.invalidate()
    pollTimer = nil
  }
}
