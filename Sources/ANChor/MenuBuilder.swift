import BoseKit
import Cocoa

@MainActor
public enum MenuBuilder {
  public static func buildMenu(
    device: BoseDevice,
    delegate: AppDelegate? = nil,
    showBatteryInBar: Bool = true,
    showModeInBar: Bool = true
  ) -> NSMenu {
    let menu = NSMenu()
    menu.delegate = delegate

    // 1. Device Header & Info Submenu
    let header = NSMenuItem(title: device.deviceName, action: nil, keyEquivalent: "")
    header.isEnabled = false
    header.attributedTitle = NSAttributedString(
      string: device.deviceName,
      attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
    )
    menu.addItem(header)

    if device.isConnected {
      // "Device Details" Submenu
      let detailsItem = NSMenuItem(title: "Device Details", action: nil, keyEquivalent: "")
      detailsItem.image = symbol("info.circle")
      let detailsMenu = NSMenu()
      detailsItem.submenu = detailsMenu

      let meta = device.metadata
      let modelName = meta.modelName ?? "Bose Headset"
      let pidStr = meta.productID != nil ? String(format: "0x%04X", meta.productID!) : ""
      addInfoRow(to: detailsMenu, title: "Model: \(modelName) \(pidStr)")

      if let fw = meta.firmwareVersion {
        addInfoRow(to: detailsMenu, title: "Firmware: \(fw)")
      }
      if let proto = meta.protocolVersion {
        addInfoRow(to: detailsMenu, title: "Protocol: BMAP \(proto)")
      }
      if let serial = meta.serialNumber {
        addInfoRow(to: detailsMenu, title: "Serial: \(serial)")
        detailsMenu.addItem(.separator())

        let copySerial = NSMenuItem(
          title: "Copy Serial Number", action: #selector(AppDelegate.copySerialNumber),
          keyEquivalent: "")
        copySerial.target = delegate
        detailsMenu.addItem(copySerial)
      }

      let copyAll = NSMenuItem(
        title: "Copy Device Info", action: #selector(AppDelegate.copyDeviceInfo), keyEquivalent: "")
      copyAll.target = delegate
      detailsMenu.addItem(copyAll)

      menu.addItem(detailsItem)
    }

    if !device.isConnected {
      let status = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
      status.isEnabled = false
      status.image = symbol("headphones.slash")
      menu.addItem(status)
      menu.addItem(.separator())
      let r = NSMenuItem(
        title: "Reconnect", action: #selector(AppDelegate.reconnect), keyEquivalent: "")
      r.target = delegate
      menu.addItem(r)
    } else {
      // 2. Battery Row
      let batt = device.batteryInfo
      if let single = batt.single {
        let b = NSMenuItem(title: "Battery · \(single)%", action: nil, keyEquivalent: "")
        b.isEnabled = false
        b.image = symbol(batterySymbol(forPercent: single))
        menu.addItem(b)
      } else if batt.hasData {
        var parts: [String] = []
        if let l = batt.left { parts.append("L \(l)%") }
        if let r = batt.right { parts.append("R \(r)%") }
        if let c = batt.caseLevel { parts.append("Case \(c)%") }
        let b = NSMenuItem(title: parts.joined(separator: " · "), action: nil, keyEquivalent: "")
        b.isEnabled = false
        if let lowest = batt.lowestLevel {
          b.image = symbol(batterySymbol(forPercent: lowest))
        }
        menu.addItem(b)
      }

      // 3. Listening Modes
      menu.addItem(sectionHeader("Listening Mode"))
      for (i, mode) in NoiseMode.allCases.enumerated() {
        let item = NSMenuItem(
          title: mode.label,
          action: #selector(AppDelegate.modeClicked(_:)),
          keyEquivalent: "\(i + 1)"
        )
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = delegate
        item.tag = Int(mode.rawValue)
        item.state = mode == device.currentMode ? .on : .off
        item.image = symbol(mode.symbolName)
        menu.addItem(item)
      }

      // Granular CNC Levels (0 to 10) for NC 700
      if device.usesDirectCNC {
        let cncSub = NSMenu()
        let cncParent = NSMenuItem(
          title: "Noise Level (Level \(device.cncLevel))", action: nil, keyEquivalent: "")
        cncParent.submenu = cncSub
        cncParent.image = symbol("slider.horizontal.below.rectangle")

        // Step 0: Quiet (Max ANC)
        let item0 = NSMenuItem(
          title: "Level 0 (Quiet — Max ANC)", action: #selector(AppDelegate.cncLevelClicked(_:)),
          keyEquivalent: "")
        item0.target = delegate
        item0.tag = 0
        item0.state = device.cncLevel == 0 ? .on : .off
        cncSub.addItem(item0)

        cncSub.addItem(.separator())

        // Steps 1 to 9
        for step in 1...9 {
          let desc = (step == 5) ? "Level \(step) (Mid)" : "Level \(step)"
          let item = NSMenuItem(
            title: desc, action: #selector(AppDelegate.cncLevelClicked(_:)), keyEquivalent: "")
          item.target = delegate
          item.tag = step
          item.state = device.cncLevel == step ? .on : .off
          cncSub.addItem(item)
        }

        cncSub.addItem(.separator())

        // Step 10: Aware (Full Transparency)
        let item10 = NSMenuItem(
          title: "Level 10 (Aware — Full Transparency)",
          action: #selector(AppDelegate.cncLevelClicked(_:)), keyEquivalent: "")
        item10.target = delegate
        item10.tag = 10
        item10.state = device.cncLevel == 10 ? .on : .off
        cncSub.addItem(item10)

        menu.addItem(cncParent)

        // Left Button Favorites (CNC Presets for NC 700)
        let favs = device.cncFavorites
        let favMenu = NSMenu()
        let favParent = NSMenuItem(
          title: "Left Button Presets (Favorites)", action: nil, keyEquivalent: "")
        favParent.submenu = favMenu
        favParent.image = symbol("star.fill")

        for (idx, level) in [favs.preset0, favs.preset1, favs.preset2].enumerated() {
          let levelLabel: String
          if level == 0 {
            levelLabel = "0 (Quiet)"
          } else if level == 10 {
            levelLabel = "10 (Aware)"
          } else if level == 5 {
            levelLabel = "5 (Mid)"
          } else {
            levelLabel = "\(level)"
          }

          let pSub = NSMenu()
          let pItem = NSMenuItem(
            title: "Preset \(idx + 1) · Level \(levelLabel)",
            action: #selector(AppDelegate.selectCncFavorite(_:)),
            keyEquivalent: ""
          )
          pItem.target = delegate
          pItem.tag = idx
          pItem.state = (favs.activeIndex == idx) ? .on : .off
          pItem.submenu = pSub

          // Submenu to configure level for this preset
          pSub.addItem(sectionHeader("Configure Level"))
          for lvl in 0...10 {
            let desc: String
            if lvl == 0 {
              desc = "Level 0 (Quiet — Max ANC)"
            } else if lvl == 5 {
              desc = "Level 5 (Mid)"
            } else if lvl == 10 {
              desc = "Level 10 (Aware — Transparency)"
            } else {
              desc = "Level \(lvl)"
            }

            let setLvlItem = NSMenuItem(
              title: desc, action: #selector(AppDelegate.setCncPresetLevel(_:)), keyEquivalent: "")
            setLvlItem.target = delegate
            setLvlItem.tag = (idx * 100) + lvl
            setLvlItem.state = (level == lvl) ? .on : .off
            pSub.addItem(setLvlItem)
          }

          favMenu.addItem(pItem)
        }

        menu.addItem(favParent)
      }

      // 4. Equalizer Submenu
      if device.hasEqualizer {
        menu.addItem(sectionHeader("Audio"))
        let eqMenu = NSMenu()
        let eqItem = NSMenuItem(title: "Equalizer", action: nil, keyEquivalent: "")
        eqItem.image = symbol("slider.horizontal.3")
        eqItem.submenu = eqMenu

        let eq = device.equalizer
        let summary =
          "Bass: \(formatDB(eq.bass))   Mid: \(formatDB(eq.mid))   Treble: \(formatDB(eq.treble))"
        let currentItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        eqMenu.addItem(currentItem)
        eqMenu.addItem(.separator())

        // Quick EQ Presets
        eqMenu.addItem(sectionHeader("Presets"))
        addPresetItem(
          to: eqMenu, title: "Flat (0 / 0 / 0)", delegate: delegate, bass: 0, mid: 0, treble: 0,
          active: eq.bass == 0 && eq.mid == 0 && eq.treble == 0)
        addPresetItem(
          to: eqMenu, title: "Bass Boost (+4 / +1 / +2)", delegate: delegate, bass: 4, mid: 1,
          treble: 2, active: eq.bass == 4 && eq.mid == 1 && eq.treble == 2)
        addPresetItem(
          to: eqMenu, title: "Vocal Boost (-1 / +3 / +1)", delegate: delegate, bass: -1, mid: 3,
          treble: 1, active: eq.bass == -1 && eq.mid == 3 && eq.treble == 1)
        addPresetItem(
          to: eqMenu, title: "Treble Boost (+1 / 0 / +4)", delegate: delegate, bass: 1, mid: 0,
          treble: 4, active: eq.bass == 1 && eq.mid == 0 && eq.treble == 4)

        eqMenu.addItem(.separator())
        addBandAdjustment(
          to: eqMenu, bandName: "Bass", bandId: EqBand.bassId, current: eq.bass, delegate: delegate)
        addBandAdjustment(
          to: eqMenu, bandName: "Mid", bandId: EqBand.midId, current: eq.mid, delegate: delegate)
        addBandAdjustment(
          to: eqMenu, bandName: "Treble", bandId: EqBand.trebleId, current: eq.treble,
          delegate: delegate)

        menu.addItem(eqItem)

        // Self Voice / Sidetone Submenu
        let sidetoneMenu = NSMenu()
        let sidetoneItem = NSMenuItem(
          title: "Self Voice (Sidetone)", action: nil, keyEquivalent: "")
        sidetoneItem.image = symbol("waveform")
        sidetoneItem.submenu = sidetoneMenu

        for lvl in [SidetoneLevel.off, SidetoneLevel.low, SidetoneLevel.medium, SidetoneLevel.high]
        {
          let item = NSMenuItem(
            title: lvl.label, action: #selector(AppDelegate.sidetoneClicked(_:)), keyEquivalent: "")
          item.target = delegate
          item.tag = Int(lvl.rawValue)
          item.state = device.sidetone == lvl ? .on : .off
          sidetoneMenu.addItem(item)
        }
        menu.addItem(sidetoneItem)

        // Media Playback Controls
        menu.addItem(sectionHeader("Playback"))
        let localPlay = NSMenuItem(
          title: "Play / Pause (Mac)", action: #selector(AppDelegate.toggleLocalPlayback),
          keyEquivalent: "")
        localPlay.target = delegate
        localPlay.image = symbol("playpause")
        menu.addItem(localPlay)

        if let second = device.secondDevice, second.isConnected {
          let remoteTitle = "Play / Pause (\(second.name))"
          let remotePlay = NSMenuItem(
            title: remoteTitle, action: #selector(AppDelegate.toggleRemotePlayback),
            keyEquivalent: "")
          remotePlay.target = delegate
          remotePlay.image = symbol("iphone")
          menu.addItem(remotePlay)
        } else {
          let remotePlay = NSMenuItem(
            title: "Play / Pause (Headphones)", action: #selector(AppDelegate.toggleRemotePlayback),
            keyEquivalent: "")
          remotePlay.target = delegate
          remotePlay.image = symbol("headphones")
          menu.addItem(remotePlay)
        }

        // Headphone Remote Volume Submenu
        let vol = device.volumeInfo
        let volMenu = NSMenu()
        let volIcon =
          (vol.current == 0)
          ? "speaker.slash.fill"
          : (vol.current <= 5
            ? "speaker.wave.1.fill"
            : (vol.current <= 11 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        let volParent = NSMenuItem(
          title: "Headphone Volume · \(vol.percentage)%", action: nil, keyEquivalent: "")
        volParent.image = symbol(volIcon)
        volParent.submenu = volMenu

        volMenu.addItem(
          createVolumeSliderItem(current: Int(vol.current), max: Int(vol.max), delegate: delegate))
        volMenu.addItem(.separator())

        let vUp = NSMenuItem(
          title: "Volume Up", action: #selector(AppDelegate.volumeUp), keyEquivalent: "")
        vUp.target = delegate
        vUp.image = symbol("plus")
        volMenu.addItem(vUp)

        let vDown = NSMenuItem(
          title: "Volume Down", action: #selector(AppDelegate.volumeDown), keyEquivalent: "")
        vDown.target = delegate
        vDown.image = symbol("minus")
        volMenu.addItem(vDown)

        volMenu.addItem(.separator())
        volMenu.addItem(sectionHeader("Presets"))

        for (pct, step) in [("100%", 16), ("75%", 12), ("50%", 8), ("25%", 4), ("Mute (0%)", 0)] {
          let pItem = NSMenuItem(
            title: pct, action: #selector(AppDelegate.setVolumeClicked(_:)), keyEquivalent: "")
          pItem.target = delegate
          pItem.tag = step
          pItem.state = (vol.current == step) ? .on : .off
          volMenu.addItem(pItem)
        }

        menu.addItem(volParent)
      }

      // 5. Device Hardware Settings
      menu.addItem(sectionHeader("Settings"))

      let voiceItem = NSMenuItem(
        title: "Voice Prompts", action: #selector(AppDelegate.toggleVoicePrompts), keyEquivalent: ""
      )
      voiceItem.target = delegate
      voiceItem.state = device.voicePromptsEnabled ? .on : .off
      voiceItem.image = symbol("bubble.left")
      menu.addItem(voiceItem)

      // Second Connected Bluetooth Device (Multipoint)
      if let second = device.secondDevice, second.isConnected {
        let badge = second.isActiveAudioSource ? " (Active Audio)" : ""
        let devTitle = "Second Device: \(second.name)\(badge)"
        let secItem = NSMenuItem(title: devTitle, action: nil, keyEquivalent: "")
        secItem.isEnabled = false
        secItem.image = symbol("iphone")
        menu.addItem(secItem)
      } else {
        let secItem = NSMenuItem(title: "Second Device: None", action: nil, keyEquivalent: "")
        secItem.isEnabled = false
        secItem.image = symbol("iphone.slash")
        menu.addItem(secItem)
      }

      // Touch Shortcut Submenu (Press & Hold on right earcup)
      let shortcutMenu = NSMenu()
      let shortcutItem = NSMenuItem(title: "Touch Shortcut (Hold)", action: nil, keyEquivalent: "")
      shortcutItem.image = symbol("hand.tap")
      shortcutItem.submenu = shortcutMenu

      for act in ShortcutAction.allCases {
        let item = NSMenuItem(
          title: act.label, action: #selector(AppDelegate.shortcutActionClicked(_:)),
          keyEquivalent: "")
        item.target = delegate
        item.tag = Int(act.rawValue)
        item.state = device.shortcutAction == act ? .on : .off
        shortcutMenu.addItem(item)
      }
      menu.addItem(shortcutItem)
    }

    // 6. Menu Bar Display Settings
    menu.addItem(sectionHeader("Menu Bar"))

    let battToggle = NSMenuItem(
      title: "Show Battery", action: #selector(AppDelegate.toggleBattery), keyEquivalent: "")
    battToggle.target = delegate
    battToggle.state = showBatteryInBar ? .on : .off
    menu.addItem(battToggle)

    let modeToggle = NSMenuItem(
      title: "Show Mode Icon", action: #selector(AppDelegate.toggleMode), keyEquivalent: "")
    modeToggle.target = delegate
    modeToggle.state = showModeInBar ? .on : .off
    menu.addItem(modeToggle)

    menu.addItem(.separator())
    let sound = NSMenuItem(
      title: "Open Sound Settings…", action: #selector(AppDelegate.openSoundSettings),
      keyEquivalent: "")
    sound.target = delegate
    menu.addItem(sound)

    let q = NSMenuItem(
      title: "Quit ANChor", action: #selector(AppDelegate.quit), keyEquivalent: "q")
    q.keyEquivalentModifierMask = [.command]
    q.target = delegate
    menu.addItem(q)

    return menu
  }

  private static func addInfoRow(to menu: NSMenu, title: String) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    menu.addItem(item)
  }

  private static func addPresetItem(
    to menu: NSMenu,
    title: String,
    delegate: AppDelegate?,
    bass: Int,
    mid: Int,
    treble: Int,
    active: Bool
  ) {
    let item = NSMenuItem(
      title: title, action: #selector(AppDelegate.presetClicked(_:)), keyEquivalent: "")
    item.target = delegate
    item.representedObject = [bass, mid, treble]
    item.state = active ? .on : .off
    menu.addItem(item)
  }

  private static func addBandAdjustment(
    to menu: NSMenu,
    bandName: String,
    bandId: UInt8,
    current: Int,
    delegate: AppDelegate?
  ) {
    let sub = NSMenu()
    let parent = NSMenuItem(
      title: "\(bandName): \(formatDB(current))", action: nil, keyEquivalent: "")
    parent.submenu = sub

    for level in stride(from: 10, through: -10, by: -1) {
      let item = NSMenuItem(
        title: formatDB(level), action: #selector(AppDelegate.eqBandClicked(_:)), keyEquivalent: "")
      item.target = delegate
      item.representedObject = ["bandId": Int(bandId), "level": level]
      item.state = (level == current) ? .on : .off
      sub.addItem(item)
    }
    menu.addItem(parent)
  }

  static func formatDB(_ val: Int) -> String {
    return val > 0 ? "+\(val) dB" : "\(val) dB"
  }

  private static func symbol(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    img?.isTemplate = true
    return img
  }

  private static func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) {
      return NSMenuItem.sectionHeader(title: title)
    }
    let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title.uppercased(),
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: 0.5,
      ]
    )
    return item
  }

  public static func createVolumeSliderItem(
    current: Int, max: Int, delegate: AppDelegate?
  ) -> NSMenuItem {
    let item = NSMenuItem()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))

    let iconName =
      (current == 0)
      ? "speaker.slash.fill" : (current <= 8 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
    let iconImg = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    iconImg?.isTemplate = true
    let iconView = NSImageView(frame: NSRect(x: 12, y: 8, width: 16, height: 16))
    iconView.image = iconImg
    iconView.contentTintColor = .secondaryLabelColor
    view.addSubview(iconView)

    let maxVal = max > 0 ? max : 16
    let pct = Int(round((Double(current) / Double(maxVal)) * 100.0))
    let label = NSTextField(labelWithString: "\(pct)%")
    label.frame = NSRect(x: 172, y: 8, width: 36, height: 16)
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .right
    label.tag = 99
    view.addSubview(label)

    let slider = NSSlider(
      value: Double(current), minValue: 0, maxValue: Double(maxVal), target: delegate,
      action: #selector(AppDelegate.volumeSliderChanged(_:)))
    slider.frame = NSRect(x: 34, y: 6, width: 134, height: 20)
    slider.controlSize = .small
    slider.isContinuous = true
    view.addSubview(slider)

    item.view = view
    return item
  }

  static func batterySymbol(forPercent p: Int) -> String {
    switch p {
    case ..<13: return "battery.0"
    case ..<38: return "battery.25"
    case ..<63: return "battery.50"
    case ..<88: return "battery.75"
    default: return "battery.100"
    }
  }
}
