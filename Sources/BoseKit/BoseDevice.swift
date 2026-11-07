import Foundation
@preconcurrency import IOBluetooth
import os

/// High-level interface to a connected Bose Bluetooth headphone or earbud.
public class BoseDevice: NSObject, IOBluetoothRFCOMMChannelDelegate {
  public static let shared = BoseDevice()

  private var channel: IOBluetoothRFCOMMChannel?
  private var responseData: [UInt8] = []
  private var responseReceived = false
  private var btThread: Thread?
  private var btRunLoop: RunLoop?
  private let ready = DispatchSemaphore(value: 0)
  private var reconnectTimer: Timer?
  private var pollTimer: Timer?
  private var connectNotification: IOBluetoothUserNotification?
  private var isConnecting = false

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
  public private(set) var shortcutAction: ShortcutAction = .batteryLevel
  public private(set) var cncFavorites: CncFavorites = CncFavorites()
  public private(set) var secondDevice: ConnectedDevice? = nil
  public private(set) var localDevice: ConnectedDevice? = nil
  public private(set) var activeSourceMac: String? = nil
  public private(set) var isRemotePlaying: Bool = false
  public private(set) var volumeInfo: VolumeInfo = VolumeInfo()
  private var localMacAddressString: String? = nil

  public var onUpdate: (() -> Void)?

  private var targetChannelID: BluetoothRFCOMMChannelID = 2
  private var lastModeChangeTime: Date = Date.distantPast
  private var pendingMode: NoiseMode = .quiet
  private var voiceLanguageId: UInt8 = 1

  public override init() {
    super.init()
    startBTThread()
    registerForConnectNotifications()
  }

  deinit {
    connectNotification?.unregister()
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
    if !isConnected && channel == nil && !isConnecting {
      connectAsync()
    }
  }

  public func log(_ msg: String, level: OSLogType = .info) {
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

  private func startBTThread() {
    btThread = Thread { [weak self] in
      self?.btRunLoop = RunLoop.current
      self?.ready.signal()
      let port = Port()
      RunLoop.current.add(port, forMode: .default)
      RunLoop.current.run()
    }
    btThread?.name = "BoseKit-BT"
    btThread?.start()
    ready.wait()
  }

  public func connectAsync() {
    perform(#selector(doConnect), on: btThread!, with: nil, waitUntilDone: false)
  }

  @objc private func doConnect() {
    guard channel == nil, !isConnected, !isConnecting else { return }
    isConnecting = true
    defer { isConnecting = false }

    guard
      let discovered = BoseDiscovery.findDevice(log: { [weak self] in self?.log($0, level: .debug) }
      )
    else {
      AppLog.bluetooth.error("❌ No Bose device found")
      startReconnectTimer()
      DispatchQueue.main.async { [weak self] in
        self?.isConnected = false
        self?.onUpdate?()
      }
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

      // Save to UserDefaults for 0ms fast-path on next launch
      if let addr = dev.addressString {
        let defaults = UserDefaults.standard
        defaults.set(addr, forKey: "lastBoseDeviceAddress")
        defaults.set(Int(targetChannelID), forKey: "lastBoseChannelID")
        defaults.set(usesDirectCNC, forKey: "lastBoseDirectCNC")
      }

      // Quick yield then fetch metadata & state
      let drainEnd = Date().addingTimeInterval(0.05)
      while Date() < drainEnd {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }

      fetchDeviceMetadata()
      doRefreshState()
      startPollTimer()
    } else {
      AppLog.bluetooth.error("❌ RFCOMM failed: \(result)")
      isConnected = false
      startReconnectTimer()
    }
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
  }

  public func disconnect() {
    stopPollTimer()
    _ = channel?.close()
    channel = nil
    isConnected = false
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
  }

  private func fetchDeviceMetadata() {
    // Query Firmware Version [0.5]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.deviceInfo, funcID: BMAPFunction.firmwareVersion,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 4 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let payload = Array(resp[4...])
        if let str = String(bytes: payload, encoding: .utf8) {
          metadata.firmwareVersion = str
          AppLog.device.info("Firmware: \(str, privacy: .public)")
        }
      }
    }

    // Query Protocol Version [0.1]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.deviceInfo, funcID: BMAPFunction.protocolVersion,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 4 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let payload = Array(resp[4...])
        if let str = String(bytes: payload, encoding: .utf8) {
          metadata.protocolVersion = str
          AppLog.device.info("Protocol: BMAP \(str, privacy: .public)")
        }
      }
    }

    // Query Serial Number [0.7]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.deviceInfo, funcID: BMAPFunction.serialNumber,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 4 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let payload = Array(resp[4...])
        if let str = String(bytes: payload, encoding: .utf8) {
          metadata.serialNumber = str
          AppLog.device.info("Serial: \(str, privacy: .public)")
        }
      }
    }
  }

  public func refreshState() {
    perform(#selector(doRefreshState), on: btThread!, with: nil, waitUntilDone: false)
  }

  @objc private func doRefreshState() {
    guard channel != nil else { return }

    // 1. Noise Mode / CNC [1.5] or [31.3]
    if usesDirectCNC {
      if let resp = sendAndWait(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cnc,
          op: BMAPOperator.get.rawValue))
      {
        if resp.count >= 6 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
          let step = resp[5]
          cncLevel = step
          if Date().timeIntervalSince(lastModeChangeTime) >= 1.5 {
            if step == 0 {
              currentMode = .quiet
            } else if step == 10 {
              currentMode = .aware
            } else {
              currentMode = nil
            }
          }
          AppLog.device.debug(
            "CNC step \(step) -> \(self.currentMode?.label ?? "Level \(step)")")
        }
      }
    } else {
      if let resp = sendAndWait(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.audioModes, funcID: BMAPFunction.currentMode,
          op: BMAPOperator.get.rawValue))
      {
        if resp.count >= 5 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
          if Date().timeIntervalSince(lastModeChangeTime) >= 1.5 {
            if let mode = NoiseMode(rawValue: resp[4]) { currentMode = mode }
          }
        }
      }
    }

    // 2. Battery [2.2]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.battery, funcID: BMAPFunction.batteryLevel,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 5 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let payload = Array(resp[4...])
        if payload.count == 4 && payload[3] == 0 {
          batteryInfo = BatteryInfo(single: Int(payload[0]))
        } else {
          var l: Int? = nil
          var r: Int? = nil
          var c: Int? = nil
          var i = 0
          while i + 3 < payload.count {
            let level = Int(payload[i])
            let devId = payload[i + 3]
            switch devId {
            case 1: l = level
            case 2: r = level
            case 3, 4: c = level
            default: break
            }
            i += 4
          }
          batteryInfo = BatteryInfo(single: nil, left: l, right: r, caseLevel: c)
        }
      }
    }

    // 3. Equalizer [1.7]
    if hasEqualizer {
      if let resp = sendAndWait(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.equalizer,
          op: BMAPOperator.get.rawValue))
      {
        if resp.count >= 4 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
          let payload = Array(resp[4...])
          var b = equalizer.bass
          var m = equalizer.mid
          var t = equalizer.treble
          var i = 0
          while i + 3 < payload.count {
            let curRaw = payload[i + 2]
            let curVal = curRaw < 128 ? Int(curRaw) : Int(curRaw) - 256
            let bandId = payload[i + 3]
            switch bandId {
            case EqBand.bassId: b = curVal
            case EqBand.midId: m = curVal
            case EqBand.trebleId: t = curVal
            default: break
            }
            i += 4
          }
          equalizer = EqualizerSettings(bass: b, mid: m, treble: t)
        }
      }
    }

    // 4. Sidetone [1.11]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.sidetone,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 6 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let rawLevel = resp[5]
        if let lvl = SidetoneLevel(rawValue: rawLevel) {
          sidetone = lvl
        }
      }
    }

    // 5. Voice Prompts [1.3]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.voicePrompts,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 5 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let first = resp[4]
        voicePromptsEnabled = ((first >> 5) & 1) == 1
        voiceLanguageId = first & 0x1F
      }
    }

    // 6. Multipoint [1.10]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.multipoint,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 5 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        multipointEnabled = resp[4] != 0
      }
    }

    // 7. Shortcut Button [1.9]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.buttons,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 7 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let actRaw = resp[6]
        if let act = ShortcutAction(rawValue: actRaw) {
          shortcutAction = act
        }
      }
    }

    // 8. CNC Favorites [1.15]
    if usesDirectCNC {
      if let resp = sendAndWait(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cncFavorites,
          op: BMAPOperator.get.rawValue))
      {
        if resp.count >= 8 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
          let actIdx = Int(resp[4])
          let p0 = Int(resp[5])
          let p1 = Int(resp[6])
          let p2 = Int(resp[7])
          cncFavorites = CncFavorites(activeIndex: actIdx, preset0: p0, preset1: p1, preset2: p2)
        }
      }
    }

    // 9. Local MAC Address [4.9]
    if localMacAddressString == nil {
      if let resp = sendAndWait(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.deviceManagement, funcID: BMAPFunction.localMacAddress,
          op: BMAPOperator.get.rawValue))
      {
        if resp.count >= 10 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
          let macBytes = Array(resp[4..<10])
          localMacAddressString = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
      }
    }

    // 10. Active Audio Source [5.1]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.audioSource,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 13 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let activeMacBytes = Array(resp[7..<13])
        activeSourceMac = activeMacBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
      }
    }

    // 11. Connected Devices [4.4]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.deviceManagement, funcID: BMAPFunction.listDevices,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 11 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let connMask = resp[4]
        var offset = 5
        var slot = 0
        var foundSecond: ConnectedDevice? = nil
        var foundLocal: ConnectedDevice? = nil
        while offset + 6 <= resp.count {
          let macBytes = Array(resp[offset..<(offset + 6)])
          let macStr = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
          let isConn = (connMask & (1 << slot)) != 0
          let isLocal = (macStr == localMacAddressString)
          let isActive = (macStr == activeSourceMac)

          var devName = isLocal ? "MacBook Pro" : "Bluetooth Device"
          if isConn {
            if let nameResp = sendAndWait(
              makeBMAPPacket(
                fblock: BMAPFunctionBlock.deviceManagement, funcID: BMAPFunction.peerDeviceInfo,
                op: BMAPOperator.get.rawValue, payload: macBytes))
            {
              if nameResp.count > 13 {
                let nameData = Array(nameResp[13...])
                if let str = String(bytes: nameData, encoding: .utf8), !str.isEmpty {
                  devName = str
                }
              }
            }
          }

          let dev = ConnectedDevice(
            macAddress: macStr, name: devName, isConnected: isConn, isLocalHost: isLocal,
            isActiveAudioSource: isActive)
          if isLocal {
            foundLocal = dev
          } else if isConn {
            foundSecond = dev
          }

          offset += 6
          slot += 1
        }
        secondDevice = foundSecond
        localDevice = foundLocal
      }
    }

    // 12. Volume Level [5.5]
    if let resp = sendAndWait(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.volume,
        op: BMAPOperator.get.rawValue))
    {
      if resp.count >= 6 && resp[2] & 0x0F == BMAPOperator.status.rawValue {
        let maxVol = resp[4]
        let curVol = resp[5]
        volumeInfo = VolumeInfo(current: curVol, max: maxVol)
      }
    }

    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
  }

  // MARK: - Control Actions

  public func setMode(_ mode: NoiseMode) {
    currentMode = mode
    lastModeChangeTime = Date()
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    pendingMode = mode
    perform(#selector(doSetMode), on: btThread!, with: nil, waitUntilDone: false)
  }

  @objc private func doSetMode() {
    let mode = pendingMode
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
      let resp = sendAndWait(
        makeBMAPPacket(
          fblock: BMAPFunctionBlock.audioModes, funcID: BMAPFunction.currentMode,
          op: BMAPOperator.start.rawValue, payload: [mode.rawValue, 0x00]))
      if let r = resp, r.count >= 5 && r[2] & 0x0F == BMAPOperator.result.rawValue {
        AppLog.device.info("✅ Mode switched")
      } else {
        AppLog.device.error("❌ Mode switch failed")
      }
    }
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
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
    lastModeChangeTime = Date()
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }

    perform(
      #selector(doSetCNC(_:)), on: btThread!, with: NSNumber(value: clamped), waitUntilDone: false)
  }

  @objc private func doSetCNC(_ num: NSNumber) {
    let step = num.uint8Value
    AppLog.device.info("setCNCLevel: \(step)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cnc,
        op: BMAPOperator.setGet.rawValue, payload: [step, 0x01]))
  }

  public func setEqualizerBand(id: UInt8, level: Int) {
    let clamped = max(-10, min(10, level))
    switch id {
    case EqBand.bassId: equalizer.bass = clamped
    case EqBand.midId: equalizer.mid = clamped
    case EqBand.trebleId: equalizer.treble = clamped
    default: break
    }
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }

    perform(
      #selector(doSetEQBand(_:)), on: btThread!,
      with: [id, UInt8(clamped < 0 ? clamped + 256 : clamped)], waitUntilDone: false)
  }

  @objc private func doSetEQBand(_ args: [UInt8]) {
    guard args.count >= 2 else { return }
    let bandId = args[0]
    let val = args[1]
    AppLog.device.info("setEQBand: band=\(bandId), val=\(val)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.equalizer,
        op: BMAPOperator.setGet.rawValue, payload: [val, bandId]))
  }

  public func setSidetone(_ level: SidetoneLevel) {
    sidetone = level
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetSidetone(_:)), on: btThread!, with: NSNumber(value: level.rawValue),
      waitUntilDone: false)
  }

  @objc private func doSetSidetone(_ num: NSNumber) {
    let val = num.uint8Value
    AppLog.device.info("setSidetone: \(val)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.sidetone,
        op: BMAPOperator.setGet.rawValue, payload: [0x01, val]))
  }

  public func setVoicePrompts(enabled: Bool) {
    voicePromptsEnabled = enabled
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetVoicePrompts(_:)), on: btThread!, with: NSNumber(value: enabled),
      waitUntilDone: false)
  }

  @objc private func doSetVoicePrompts(_ num: NSNumber) {
    let en = num.boolValue
    let payloadByte = (en ? 0x20 : 0x00) | (voiceLanguageId & 0x1F)
    AppLog.device.info("setVoicePrompts: enabled=\(en)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.voicePrompts,
        op: BMAPOperator.setGet.rawValue, payload: [payloadByte]))
  }

  public func setMultipoint(enabled: Bool) {
    multipointEnabled = enabled
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetMultipoint(_:)), on: btThread!, with: NSNumber(value: enabled),
      waitUntilDone: false)
  }

  @objc private func doSetMultipoint(_ num: NSNumber) {
    let en = num.boolValue
    AppLog.device.info("setMultipoint: \(en)")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.multipoint,
        op: BMAPOperator.setGet.rawValue, payload: [en ? 0x01 : 0x00]))
  }

  public func setShortcutAction(_ action: ShortcutAction) {
    shortcutAction = action
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetShortcut(_:)), on: btThread!, with: NSNumber(value: action.rawValue),
      waitUntilDone: false)
  }

  @objc private func doSetShortcut(_ num: NSNumber) {
    let act = num.uint8Value
    AppLog.device.info("setShortcutAction: \(act)")
    // button_id 0x80 (Shortcut touch surface), event 0x05 (press and hold)
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.buttons,
        op: BMAPOperator.setGet.rawValue, payload: [0x80, 0x05, act]))
  }

  public func setCncFavorites(preset0: Int, preset1: Int, preset2: Int) {
    let p0 = UInt8(clamping: preset0)
    let p1 = UInt8(clamping: preset1)
    let p2 = UInt8(clamping: preset2)
    let curIdx = UInt8(cncFavorites.activeIndex)
    cncFavorites.preset0 = Int(p0)
    cncFavorites.preset1 = Int(p1)
    cncFavorites.preset2 = Int(p2)
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetCncFavorites(_:)), on: btThread!, with: [curIdx, p0, p1, p2],
      waitUntilDone: false)
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
    lastModeChangeTime = Date()
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetCncFavorites(_:)), on: btThread!, with: [idx, p0, p1, p2], waitUntilDone: false
    )
  }

  @objc private func doSetCncFavorites(_ arr: [UInt8]) {
    guard arr.count == 4 else { return }
    AppLog.device.info("setCncFavorites: idx=\(arr[0]) p0=\(arr[1]) p1=\(arr[2]) p2=\(arr[3])")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.settings, funcID: BMAPFunction.cncFavorites,
        op: BMAPOperator.setGet.rawValue, payload: arr))
  }

  // MARK: - Remote Media Transport Controls

  public func sendRemotePlay() {
    AppLog.device.info("sendRemotePlay")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.audioControl,
        op: BMAPOperator.start.rawValue, payload: [0x01]))
    isRemotePlaying = true
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
  }

  public func sendRemotePause() {
    AppLog.device.info("sendRemotePause")
    sendRawPacket(
      makeBMAPPacket(
        fblock: BMAPFunctionBlock.audioManagement, funcID: BMAPFunction.audioControl,
        op: BMAPOperator.start.rawValue, payload: [0x02]))
    isRemotePlaying = false
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
  }

  public func toggleRemotePlayback() {
    if isRemotePlaying {
      sendRemotePause()
    } else {
      sendRemotePlay()
    }
  }

  // MARK: - Remote Volume Controls

  public func setVolume(_ level: UInt8) {
    let clamped = min(max(level, 0), volumeInfo.max)
    volumeInfo.current = clamped
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    perform(
      #selector(doSetVolume(_:)), on: btThread!, with: NSNumber(value: clamped),
      waitUntilDone: false)
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

  @objc private func doSetVolume(_ num: NSNumber) {
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

  private func sendAndWait(_ packet: [UInt8], timeout: TimeInterval = 1.0) -> [UInt8]? {
    guard let channel = channel else { return nil }
    responseData = []
    responseReceived = false

    var pkt = packet
    let writeOK = pkt.withUnsafeMutableBufferPointer { buf -> Bool in
      return channel.writeSync(buf.baseAddress!, length: UInt16(buf.count)) == kIOReturnSuccess
    }
    guard writeOK else {
      AppLog.protocol.error("BMAP write failed")
      return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && !responseReceived {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return responseReceived ? responseData : nil
  }

  // MARK: - RFCOMM Delegate

  public func rfcommChannelData(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int
  ) {
    let bytes = Array(
      UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: len))
    AppLog.protocol.debug(
      "RX(\(len, privacy: .public)): \(bytes.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)"
    )

    // Unsolicited mode change [31.3]
    if bytes.count >= 5 && bytes[0] == BMAPFunctionBlock.audioModes
      && bytes[1] == BMAPFunction.currentMode && bytes[2] & 0x0F == BMAPOperator.status.rawValue
    {
      if let mode = NoiseMode(rawValue: bytes[4]) {
        if mode != currentMode {
          AppLog.device.info("📡 Unsolicited mode change: \(mode.label, privacy: .public)")
          currentMode = mode
          DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
        }
      }
    }

    // Unsolicited CNC change [1.5]
    if bytes.count >= 6 && bytes[0] == BMAPFunctionBlock.settings && bytes[1] == BMAPFunction.cnc
      && bytes[2] & 0x0F == BMAPOperator.status.rawValue
    {
      let step = bytes[5]
      let stepChanged = (step != cncLevel)
      cncLevel = step
      if Date().timeIntervalSince(lastModeChangeTime) >= 1.5 {
        let newMode: NoiseMode?
        if step == 0 {
          newMode = .quiet
        } else if step == 10 {
          newMode = .aware
        } else {
          newMode = nil
        }
        if stepChanged || newMode != currentMode {
          AppLog.device.info(
            "📡 CNC change: step \(step) -> \(newMode?.label ?? "Level \(step)", privacy: .public)")
          currentMode = newMode
          DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
        }
      }
    }

    // Unsolicited CNC Favorites change [1.15] (Left physical button press)
    if bytes.count >= 8 && bytes[0] == BMAPFunctionBlock.settings
      && bytes[1] == BMAPFunction.cncFavorites && bytes[2] & 0x0F == BMAPOperator.status.rawValue
    {
      let actIdx = Int(bytes[4])
      let p0 = Int(bytes[5])
      let p1 = Int(bytes[6])
      let p2 = Int(bytes[7])
      let newFav = CncFavorites(activeIndex: actIdx, preset0: p0, preset1: p1, preset2: p2)
      if newFav.activeIndex != cncFavorites.activeIndex || newFav.preset0 != cncFavorites.preset0
        || newFav.preset1 != cncFavorites.preset1 || newFav.preset2 != cncFavorites.preset2
      {
        AppLog.device.info(
          "📡 CNC favorites change: active=\(actIdx) [\(p0), \(p1), \(p2)]")
        cncFavorites = newFav
        DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
      }
    }

    // Button status / confirmation [1.9]
    if bytes.count >= 7 && bytes[0] == BMAPFunctionBlock.settings
      && bytes[1] == BMAPFunction.buttons && bytes[2] & 0x0F == BMAPOperator.status.rawValue
    {
      let actRaw = bytes[6]
      if let act = ShortcutAction(rawValue: actRaw) {
        if act != shortcutAction {
          AppLog.device.info("📡 Button shortcut confirmed: \(act.label, privacy: .public)")
          shortcutAction = act
          DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
        }
      }
    }

    // Unsolicited Audio Source change [5.1]
    if bytes.count >= 13 && bytes[0] == BMAPFunctionBlock.audioManagement
      && bytes[1] == BMAPFunction.audioSource && bytes[2] & 0x0F == BMAPOperator.status.rawValue
    {
      let activeMacBytes = Array(bytes[7..<13])
      let newMac = activeMacBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
      if newMac != activeSourceMac {
        activeSourceMac = newMac
        AppLog.device.info(
          "📡 Active audio source change: \(newMac, privacy: .public)"
        )
        DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
      }
    }

    // Unsolicited Volume change [5.5]
    if bytes.count >= 6 && bytes[0] == BMAPFunctionBlock.audioManagement
      && bytes[1] == BMAPFunction.volume && bytes[2] & 0x0F == BMAPOperator.status.rawValue
    {
      let maxVol = bytes[4]
      let curVol = bytes[5]
      if curVol != volumeInfo.current || maxVol != volumeInfo.max {
        volumeInfo = VolumeInfo(current: curVol, max: maxVol)
        AppLog.device.info(
          "📡 Volume change: \(curVol)/\(maxVol) (\(self.volumeInfo.percentage)%)")
        DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
      }
    }

    responseData = bytes
    responseReceived = true
  }

  public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    AppLog.bluetooth.notice("RFCOMM channel closed")
    channel = nil
    isConnected = false
    stopPollTimer()
    startReconnectTimer()
    DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
  }

  // MARK: - Timers

  private func startReconnectTimer() {
    stopReconnectTimer()
    perform(#selector(scheduleReconnectTimer), on: btThread!, with: nil, waitUntilDone: false)
  }

  @objc private func scheduleReconnectTimer() {
    reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
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

  private func startPollTimer() {
    stopPollTimer()
    perform(#selector(schedulePollTimer), on: btThread!, with: nil, waitUntilDone: false)
  }

  @objc private func schedulePollTimer() {
    pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
      guard let self = self, self.channel != nil else { return }
      self.doRefreshState()
    }
  }

  private func stopPollTimer() {
    pollTimer?.invalidate()
    pollTimer = nil
  }
}
