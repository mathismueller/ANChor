import Cocoa
import BoseKit

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public var statusItem: NSStatusItem!
    public let bose = BoseDevice.shared

    private let defaults = UserDefaults.standard
    private let kShowBattery = "showBatteryInBar"
    private let kShowMode = "showModeInBar"

    public var showBatteryInBar: Bool {
        get { defaults.bool(forKey: kShowBattery) }
        set { defaults.set(newValue, forKey: kShowBattery); updateUI() }
    }
    public var showModeInBar: Bool {
        get { defaults.bool(forKey: kShowMode) }
        set { defaults.set(newValue, forKey: kShowMode); updateUI() }
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
        bose.log("UI: modeClicked → \(mode.label)")
        bose.setMode(mode)
    }

    @objc public func cncLevelClicked(_ sender: NSMenuItem) {
        let step = UInt8(sender.tag)
        bose.log("UI: cncLevelClicked → \(step)")
        bose.setCNCLevel(step)
    }

    @objc public func presetClicked(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Int], values.count == 3 else { return }
        bose.log("UI: presetClicked → Bass: \(values[0]), Mid: \(values[1]), Treble: \(values[2])")
        bose.setEqualizerBand(id: EqBand.bassId, level: values[0])
        bose.setEqualizerBand(id: EqBand.midId, level: values[1])
        bose.setEqualizerBand(id: EqBand.trebleId, level: values[2])
    }

    @objc public func eqBandClicked(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Int],
              let bandId = dict["bandId"],
              let level = dict["level"] else { return }
        bose.log("UI: eqBandClicked → band \(bandId) = \(level)")
        bose.setEqualizerBand(id: UInt8(bandId), level: level)
    }

    @objc public func sidetoneClicked(_ sender: NSMenuItem) {
        guard let lvl = SidetoneLevel(rawValue: UInt8(sender.tag)) else { return }
        bose.log("UI: sidetoneClicked → \(lvl.label)")
        bose.setSidetone(lvl)
    }

    @objc public func toggleVoicePrompts() {
        let newState = !bose.voicePromptsEnabled
        bose.log("UI: toggleVoicePrompts → \(newState)")
        bose.setVoicePrompts(enabled: newState)
    }

    @objc public func toggleMultipoint() {
        let newState = !bose.multipointEnabled
        bose.log("UI: toggleMultipoint → \(newState)")
        bose.setMultipoint(enabled: newState)
    }

    @objc public func shortcutActionClicked(_ sender: NSMenuItem) {
        guard let act = ShortcutAction(rawValue: UInt8(sender.tag)) else { return }
        bose.log("UI: shortcutActionClicked → \(act.label)")
        bose.setShortcutAction(act)
    }

    @objc public func selectCncFavorite(_ sender: NSMenuItem) {
        let index = sender.tag
        bose.log("UI: selectCncFavorite → index \(index)")
        bose.selectCncFavorite(index: index)
    }

    @objc public func setCncPresetLevel(_ sender: NSMenuItem) {
        let presetIdx = sender.tag / 100
        let level = sender.tag % 100
        bose.log("UI: setCncPresetLevel → preset \(presetIdx) = level \(level)")
        var fav = bose.cncFavorites
        if presetIdx == 0 { fav.preset0 = level }
        else if presetIdx == 1 { fav.preset1 = level }
        else if presetIdx == 2 { fav.preset2 = level }
        bose.setCncFavorites(preset0: fav.preset0, preset1: fav.preset1, preset2: fav.preset2)
    }

    @objc public func copySerialNumber() {
        if let serial = bose.metadata.serialNumber {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(serial, forType: .string)
            bose.log("UI: copied serial number \(serial)")
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
        bose.log("UI: copied device info summary")
    }

    @objc public func reconnect() {
        bose.log("UI: reconnect requested")
        bose.disconnect()
        bose.connectAsync()
    }

    @objc public func toggleBattery() {
        showBatteryInBar = !showBatteryInBar
        bose.log("UI: showBatteryInBar = \(showBatteryInBar)")
    }

    @objc public func toggleMode() {
        showModeInBar = !showModeInBar
        bose.log("UI: showModeInBar = \(showModeInBar)")
    }

    @objc public func quit() {
        bose.log("UI: quit")
        bose.disconnect()
        NSApp.terminate(nil)
    }

    @objc public func openSoundSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
        bose.log("UI: openSoundSettings → \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        bose.log("UI: menuWillOpen (connected=\(bose.isConnected))")
        if bose.isConnected {
            bose.refreshState()
        }
    }
}
