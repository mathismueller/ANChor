import BoseKit
import Cocoa
import ServiceManagement
import os

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  public var statusItem: NSStatusItem!
  public let bose = BoseDevice.shared
  private weak var activeMenu: NSMenu?

  private let defaults = UserDefaults.standard
  private let kShowBattery = "showBatteryInBar"
  private let kShowMode = "showModeInBar"

  public var showBatteryInBar: Bool {
    get { defaults.bool(forKey: kShowBattery) }
    set {
      defaults.set(newValue, forKey: kShowBattery)
      updateUI()
    }
  }
  public var showModeInBar: Bool {
    get { defaults.bool(forKey: kShowMode) }
    set {
      defaults.set(newValue, forKey: kShowMode)
      updateUI()
    }
  }

  public var startAtLogin: Bool {
    get {
      if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
      }
      return defaults.bool(forKey: "startAtLogin")
    }
    set {
      if #available(macOS 13.0, *) {
        do {
          if newValue {
            if SMAppService.mainApp.status != .enabled {
              try SMAppService.mainApp.register()
            }
          } else {
            if SMAppService.mainApp.status == .enabled {
              try SMAppService.mainApp.unregister()
            }
          }
        } catch {
          AppLog.ui.error(
            "Failed to toggle Start at Login: \(error.localizedDescription, privacy: .public)")
        }
      }
      defaults.set(newValue, forKey: "startAtLogin")
      updateUI()
    }
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.imagePosition = .imageLeading
      button.image = barImage()
    }
    bose.onUpdate = { [weak self] in
      Task { @MainActor [weak self] in
        self?.updateUI()
      }
    }
    updateUI()
    bose.connectAsync()
  }

  private func barImage() -> NSImage? {
    let name: String
    let accessibility: String
    if !bose.isConnected {
      name = "headphones.slash"
      accessibility = "ANChor — not connected"
    } else if showModeInBar {
      if let mode = bose.currentMode {
        name = mode.symbolName
        accessibility = "ANChor — \(mode.label)"
      } else {
        name = (bose.cncLevel <= 5) ? "waveform.slash" : "ear"
        accessibility = "ANChor — Level \(cncDisplayLevel(raw: bose.cncLevel))"
      }
    } else {
      name = "headphones"
      let modeLabel = bose.currentMode?.label ?? "Level \(cncDisplayLevel(raw: bose.cncLevel))"
      accessibility = "ANChor — \(modeLabel)"
    }
    let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)
    img?.isTemplate = true
    return img
  }

  public func updateUI() {
    if let button = statusItem.button {
      button.image = barImage()
      if bose.isConnected && showBatteryInBar {
        let batt = bose.batteryInfo
        if let single = batt.single {
          button.title = " \(single)%"
        } else if let lowest = batt.lowestLevel {
          button.title = " \(lowest)%"
        } else {
          button.title = ""
        }
      } else {
        button.title = ""
      }
    }

    if let openMenu = activeMenu ?? statusItem.menu {
      updateListeningModeItems(in: openMenu, level: bose.cncLevel)
      updateNoiseSliderItem(in: openMenu, level: bose.cncLevel)
      updateVolumeSliderItem(in: openMenu, volume: bose.volumeInfo)
      updateAudioSourceItems(in: openMenu, device: bose)
    }

    if activeMenu == nil {
      statusItem.menu = MenuBuilder.buildMenu(
        device: bose,
        delegate: self,
        showBatteryInBar: showBatteryInBar,
        showModeInBar: showModeInBar,
        startAtLogin: startAtLogin
      )
    }
  }

  // MARK: - User Actions

  @objc public func modeClicked(_ sender: NSMenuItem) {
    guard let mode = NoiseMode(rawValue: UInt8(sender.tag)) else { return }
    AppLog.ui.info("modeClicked → \(mode.label, privacy: .public)")
    bose.setMode(mode)
  }

  @objc public func cncLevelClicked(_ sender: NSMenuItem) {
    let step = UInt8(sender.tag)
    AppLog.ui.info("cncLevelClicked → \(step)")
    bose.setCNCLevel(step)
  }

  @objc public func cncSliderChanged(_ sender: NSSlider) {
    let shown = Int(round(sender.doubleValue))
    let raw = cncRawLevel(displayed: shown)
    if let container = sender.superview {
      if let label = container.viewWithTag(99) as? NSTextField {
        label.stringValue = "Level \(shown)"
      }
      if let iconView = container.viewWithTag(98) as? NSImageView {
        let iconName = (shown >= 5) ? "waveform.slash" : "ear"
        let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        img?.isTemplate = true
        iconView.image = img
      }
    }

    let targetMenu = sender.enclosingMenuItem?.menu ?? activeMenu ?? statusItem.menu
    if let menu = targetMenu {
      updateListeningModeItems(in: menu, level: raw)
    }

    if raw != bose.cncLevel {
      AppLog.ui.debug("cncSliderChanged → shown \(shown) (raw \(raw))")
      bose.setCNCLevel(raw)
    }
  }

  @objc public func presetClicked(_ sender: NSMenuItem) {
    guard let values = sender.representedObject as? [Int], values.count == 3 else { return }
    AppLog.ui.info("presetClicked → Bass: \(values[0]), Mid: \(values[1]), Treble: \(values[2])")
    bose.setEqualizerBand(id: EqBand.bassId, level: values[0])
    bose.setEqualizerBand(id: EqBand.midId, level: values[1])
    bose.setEqualizerBand(id: EqBand.trebleId, level: values[2])
  }

  @objc public func eqBandClicked(_ sender: NSMenuItem) {
    guard let dict = sender.representedObject as? [String: Int],
      let bandId = dict["bandId"],
      let level = dict["level"]
    else { return }
    AppLog.ui.info("eqBandClicked → band \(bandId) = \(level)")
    bose.setEqualizerBand(id: UInt8(bandId), level: level)
  }

  @objc public func sidetoneClicked(_ sender: NSMenuItem) {
    guard let lvl = SidetoneLevel(rawValue: UInt8(sender.tag)) else { return }
    AppLog.ui.info("sidetoneClicked → \(lvl.label, privacy: .public)")
    bose.setSidetone(lvl)
  }

  @objc public func toggleVoicePrompts() {
    let newState = !bose.voicePromptsEnabled
    AppLog.ui.info("toggleVoicePrompts → \(newState)")
    bose.setVoicePrompts(enabled: newState)
  }

  @objc public func standbyTimerClicked(_ sender: NSMenuItem) {
    let mins = UInt8(clamping: sender.tag)
    AppLog.ui.info("standbyTimerClicked → \(mins) min")
    bose.setStandbyTimer(mins)
  }

  @objc public func shortcutActionClicked(_ sender: NSMenuItem) {
    guard let act = ShortcutAction(rawValue: UInt8(sender.tag)) else { return }
    AppLog.ui.info("shortcutActionClicked → \(act.label, privacy: .public)")
    bose.setShortcutAction(act)
  }

  @objc public func selectCncFavorite(_ sender: NSMenuItem) {
    let index = sender.tag
    AppLog.ui.info("selectCncFavorite → index \(index)")
    bose.selectCncFavorite(index: index)
  }

  @objc public func setCncPresetLevel(_ sender: NSMenuItem) {
    let presetIdx = sender.tag / 100
    let level = sender.tag % 100
    AppLog.ui.info("setCncPresetLevel → preset \(presetIdx) = level \(level)")
    var fav = bose.cncFavorites
    if presetIdx == 0 {
      fav.preset0 = level
    } else if presetIdx == 1 {
      fav.preset1 = level
    } else if presetIdx == 2 {
      fav.preset2 = level
    }
    bose.setCncFavorites(preset0: fav.preset0, preset1: fav.preset1, preset2: fav.preset2)
  }

  @objc public func toggleRemotePlayback() {
    AppLog.ui.info("toggleRemotePlayback")
    bose.toggleRemotePlayback()
  }

  @objc public func volumeUp() {
    AppLog.ui.info("volumeUp")
    bose.volumeUp()
  }

  @objc public func volumeDown() {
    AppLog.ui.info("volumeDown")
    bose.volumeDown()
  }

  @objc public func volumeSliderChanged(_ sender: NSSlider) {
    let level = UInt8(clamping: Int(round(sender.doubleValue)))
    if let container = sender.superview {
      let maxVal = Double(bose.volumeInfo.max > 0 ? bose.volumeInfo.max : 16)
      let pct = Int(round((sender.doubleValue / maxVal) * 100.0))
      if let label = container.viewWithTag(99) as? NSTextField {
        label.stringValue = "\(pct)%"
      }
      if let iconView = container.viewWithTag(98) as? NSImageView {
        let iconName =
          (level == 0)
          ? "speaker.slash.fill" : (level <= 8 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
        let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        img?.isTemplate = true
        iconView.image = img
      }
    }
    if level != bose.volumeInfo.current {
      AppLog.ui.debug("volumeSliderChanged → \(level)")
      bose.setVolume(level)
    }
  }

  @objc public func setVolumeClicked(_ sender: NSMenuItem) {
    let level = UInt8(clamping: sender.tag)
    AppLog.ui.info("setVolumeClicked → \(level)")
    bose.setVolume(level)
  }

  @objc public func connectPairedDeviceClicked(_ sender: NSMenuItem) {
    guard let mac = sender.representedObject as? String else { return }
    AppLog.ui.info("connectPairedDeviceClicked → \(mac, privacy: .public)")
    bose.connectPairedDevice(mac: mac)
  }

  @objc public func copySerialNumber() {
    if let serial = bose.metadata.serialNumber {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(serial, forType: .string)
      AppLog.ui.info("copied serial number")
    }
  }

  @objc public func copyDeviceInfo() {
    var lines: [String] = []
    lines.append("Device Name: \(bose.deviceName)")
    if let model = bose.metadata.modelName { lines.append("Model: \(model)") }
    if let pid = bose.metadata.productID { lines.append(String(format: "Product ID: 0x%04X", pid)) }
    if let fw = bose.metadata.firmwareVersion { lines.append("Firmware: \(fw)") }
    if let proto = bose.metadata.protocolVersion { lines.append("Protocol: BMAP \(proto)") }
    if let serial = bose.metadata.serialNumber { lines.append("Serial Number: \(serial)") }
    if let guid = bose.metadata.productGuid { lines.append("Product GUID [0.12]: \(guid)") }
    lines.append("Motion Auto-off [1.20]: \(bose.motionAutoOffEnabled ? "On" : "Off") (read-only)")
    if let name = bose.metadata.deviceName { lines.append("BMAP Name [1.2]: \(name)") }
    if let codename = bose.metadata.reportedCodename {
      lines.append("Codename [18.12]: \(codename)")
    }
    if let plat = bose.metadata.platformName { lines.append("Platform [18.13]: \(plat)") }
    if let standby = bose.metadata.standbyTimer {
      lines.append(
        standby == 0 ? "Auto-off [1.4]: Never" : "Auto-off [1.4]: \(standby) min")
    }
    for dev in bose.pairedDevices {
      let state =
        dev.isConnected ? (dev.isActiveAudioSource ? "connected, active" : "connected") : "paired"
      lines.append("Paired: \(dev.name) [\(dev.macAddress)] (\(state))")
    }
    if let batt = bose.batteryInfo.lowestLevel { lines.append("Battery: \(batt)%") }

    let text = lines.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    AppLog.ui.info("copied device info summary")
  }

  @objc public func reconnect() {
    AppLog.ui.info("reconnect requested")
    bose.disconnect()
    bose.connectAsync()
  }

  @objc public func toggleStartAtLogin() {
    startAtLogin = !startAtLogin
    AppLog.ui.info("toggleStartAtLogin → \(self.startAtLogin)")
  }

  @objc public func toggleBattery() {
    showBatteryInBar = !showBatteryInBar
    AppLog.ui.info("showBatteryInBar = \(self.showBatteryInBar)")
  }

  @objc public func toggleMode() {
    showModeInBar = !showModeInBar
    AppLog.ui.info("showModeInBar = \(self.showModeInBar)")
  }

  @objc public func quit() {
    AppLog.ui.info("quit")
    bose.disconnect()
    NSApp.terminate(nil)
  }

  @objc public func openSoundSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
    AppLog.ui.info("openSoundSettings → \(url.absoluteString, privacy: .public)")
    NSWorkspace.shared.open(url)
  }

  public func menuWillOpen(_ menu: NSMenu) {
    activeMenu = menu
    AppLog.ui.debug("menuWillOpen (connected=\(self.bose.isConnected, privacy: .public))")
    if bose.isConnected {
      bose.refreshState()
    }
  }

  public func menuDidClose(_ menu: NSMenu) {
    activeMenu = nil
    statusItem.menu = MenuBuilder.buildMenu(
      device: bose,
      delegate: self,
      showBatteryInBar: showBatteryInBar,
      showModeInBar: showModeInBar,
      startAtLogin: startAtLogin
    )
  }

  public func updateListeningModeItems(in menu: NSMenu, level: UInt8) {
    for item in menu.items {
      if item.action == #selector(modeClicked(_:)) {
        if item.tag == Int(NoiseMode.quiet.rawValue) {
          item.state = (level == 0) ? .on : .off
        } else if item.tag == Int(NoiseMode.aware.rawValue) {
          item.state = (level == 10) ? .on : .off
        }
      }
    }
  }

  public func updateNoiseSliderItem(in menu: NSMenu, level: UInt8) {
    let shown = cncDisplayLevel(raw: level)
    guard let item = menu.items.first(where: { $0.tag == 777 }), let container = item.view else {
      return
    }
    if let slider = container.viewWithTag(97) as? NSSlider {
      if Int(round(slider.doubleValue)) != shown {
        slider.doubleValue = Double(shown)
      }
    }
    if let label = container.viewWithTag(99) as? NSTextField {
      label.stringValue = "Level \(shown)"
    }
    if let iconView = container.viewWithTag(98) as? NSImageView {
      let iconName = (shown >= 5) ? "waveform.slash" : "ear"
      let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
      img?.isTemplate = true
      iconView.image = img
    }
  }

  public func updateVolumeSliderItem(in menu: NSMenu, volume: VolumeInfo) {
    guard let item = menu.items.first(where: { $0.tag == 778 }), let container = item.view else {
      return
    }
    let maxVal = Double(volume.max > 0 ? volume.max : 16)
    if let slider = container.viewWithTag(96) as? NSSlider {
      slider.maxValue = maxVal
      if UInt8(clamping: Int(round(slider.doubleValue))) != volume.current {
        slider.doubleValue = Double(volume.current)
      }
    }
    if let label = container.viewWithTag(99) as? NSTextField {
      let pct = Int(round((Double(volume.current) / maxVal) * 100.0))
      label.stringValue = "\(pct)%"
    }
    if let iconView = container.viewWithTag(98) as? NSImageView {
      let iconName =
        (volume.current == 0)
        ? "speaker.slash.fill"
        : (volume.current <= 8 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
      let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
      img?.isTemplate = true
      iconView.image = img
    }
  }

  public func updateAudioSourceItems(in menu: NSMenu, device: BoseDevice) {
    if let item = menu.items.first(where: { $0.tag == 781 }) {
      if let local = device.localDevice {
        let badge = local.isActiveAudioSource ? " (Active Audio)" : ""
        item.title = "This Mac: \(local.name)\(badge)"
        item.state = local.isActiveAudioSource ? .on : .off
      }
    }
    if let item = menu.items.first(where: { $0.tag == 782 }) {
      if let second = device.secondDevice, second.isConnected {
        let badge = second.isActiveAudioSource ? " (Active Audio)" : ""
        item.title = "Second Device: \(second.name)\(badge)"
        item.state = second.isActiveAudioSource ? .on : .off
      } else {
        item.title = "Second Device: None"
        item.state = .off
      }
    }
    if let item = menu.items.first(where: { $0.tag == 783 }) {
      item.title = "Motion Auto-off: \(device.motionAutoOffEnabled ? "On" : "Off")"
    }
  }
}
