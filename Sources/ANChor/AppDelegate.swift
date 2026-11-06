import BoseKit
import Cocoa
import os

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  public var statusItem: NSStatusItem!
  public let bose = BoseDevice.shared

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
      name = bose.currentMode.symbolName
      accessibility = "ANChor — \(bose.currentMode.label)"
    } else {
      name = "headphones"
      accessibility = "ANChor — \(bose.currentMode.label)"
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

    statusItem.menu = MenuBuilder.buildMenu(
      device: bose,
      delegate: self,
      showBatteryInBar: showBatteryInBar,
      showModeInBar: showModeInBar
    )
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
    let step = UInt8(clamping: Int(round(sender.doubleValue)))
    if let container = sender.superview {
      if let label = container.viewWithTag(99) as? NSTextField {
        label.stringValue = "Level \(step)"
      }
      if let iconView = container.viewWithTag(98) as? NSImageView {
        let iconName = (step <= 5) ? "waveform.slash" : "ear"
        let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        img?.isTemplate = true
        iconView.image = img
      }
    }
    if step != bose.cncLevel {
      AppLog.ui.debug("cncSliderChanged → \(step)")
      bose.setCNCLevel(step)
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

  @objc public func toggleLocalPlayback() {
    AppLog.ui.info("toggleLocalPlayback")
    func postMediaKey(down: Bool) {
      let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
      let data1 = (Int(NX_KEYTYPE_PLAY) << 16) | (down ? 0xa00 : 0xb00)
      let ev = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1
      )
      ev?.cgEvent?.post(tap: .cghidEventTap)
    }
    postMediaKey(down: true)
    postMediaKey(down: false)
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
    AppLog.ui.debug("menuWillOpen (connected=\(self.bose.isConnected, privacy: .public))")
    if bose.isConnected {
      bose.refreshState()
    }
  }
}
