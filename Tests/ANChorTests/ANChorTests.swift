import AppKit
import Testing

@testable import ANChor
@testable import BoseKit

@Suite("ANChor UI Tests")
@MainActor
struct ANChorTests {

  @Test func disconnectedMenuStructure() throws {
    let device = BoseDevice(transport: nil)
    let menu = MenuBuilder.buildMenu(device: device, delegate: nil)

    #expect(menu.items.first?.title == device.deviceName)

    let titles = menu.items.map(\.title)
    #expect(titles.contains("Not connected"))
    #expect(titles.contains("Reconnect"))
    #expect(titles.contains("Start at Login"))

    let loginItem = try #require(menu.items.first { $0.title == "Start at Login" })
    #expect(loginItem.action == #selector(AppDelegate.toggleStartAtLogin))
    #expect(loginItem.state == .off)

    let menuEnabled = MenuBuilder.buildMenu(device: device, delegate: nil, startAtLogin: true)
    let loginItemEnabled = try #require(menuEnabled.items.first { $0.title == "Start at Login" })
    #expect(loginItemEnabled.state == .on)

    let quitItem = try #require(menu.items.first { $0.title == "Quit ANChor" })
    #expect(quitItem.action == #selector(AppDelegate.quit))
    #expect(quitItem.keyEquivalent == "q")
  }

  @Test func formatDB() {
    #expect(MenuBuilder.formatDB(0) == "0 dB")
    #expect(MenuBuilder.formatDB(4) == "+4 dB")
    #expect(MenuBuilder.formatDB(-3) == "-3 dB")
  }

  @Test(arguments: [
    (percent: 100, symbol: "battery.100"),
    (percent: 85, symbol: "battery.75"),
    (percent: 50, symbol: "battery.50"),
    (percent: 25, symbol: "battery.25"),
    (percent: 10, symbol: "battery.0"),
  ])
  func batterySymbolMapping(percent: Int, symbol: String) {
    #expect(MenuBuilder.batterySymbol(forPercent: percent) == symbol)
  }

  @Test func volumeSliderItemCreation() throws {
    let item = MenuBuilder.createVolumeSliderItem(current: 8, max: 16, delegate: nil)
    let sliderView = try #require(item.view as? VolumeSliderView)
    #expect(sliderView.slider.doubleValue == 8.0)
    #expect(sliderView.slider.maxValue == 16.0)
    #expect(sliderView.valueLabel.stringValue == "50%")

    sliderView.update(current: 0, max: 16, syncSlider: true)
    #expect(sliderView.slider.doubleValue == 0.0)
    #expect(sliderView.valueLabel.stringValue == "0%")
  }

  @Test func noiseLevelSliderItemCreation() throws {
    let item = MenuBuilder.createNoiseLevelSliderItem(current: 5, delegate: nil)
    let sliderView = try #require(item.view as? NoiseLevelSliderView)
    #expect(sliderView.slider.doubleValue == 5.0)
    #expect(sliderView.slider.maxValue == 10.0)
    #expect(sliderView.slider.numberOfTickMarks == 11)
    #expect(sliderView.slider.allowsTickMarkValuesOnly)
    #expect(sliderView.valueLabel.stringValue == "Level 5")

    sliderView.update(displayed: 10, syncSlider: true)
    #expect(sliderView.slider.doubleValue == 10.0)
    #expect(sliderView.valueLabel.stringValue == "Level 10")
  }

  @Test func listeningModeCheckedOnlyAtRespectiveLevels() {
    let device = BoseDevice(transport: nil)
    device.setConnectedForTesting(true)
    device.setDirectCNCForTesting(true)

    // At Level 0: Quiet is ON, Aware is OFF
    device.setCNCLevel(0)
    let menu0 = MenuBuilder.buildMenu(device: device, delegate: nil)
    #expect(menu0.items.first { $0.title == "Quiet" }?.state == .on)
    #expect(menu0.items.first { $0.title == "Aware" }?.state == .off)

    // At Level 10: Quiet is OFF, Aware is ON
    device.setCNCLevel(10)
    let menu10 = MenuBuilder.buildMenu(device: device, delegate: nil)
    #expect(menu10.items.first { $0.title == "Quiet" }?.state == .off)
    #expect(menu10.items.first { $0.title == "Aware" }?.state == .on)

    // At intermediate Level 5: BOTH Quiet and Aware are OFF
    device.setCNCLevel(5)
    let menu5 = MenuBuilder.buildMenu(device: device, delegate: nil)
    #expect(menu5.items.first { $0.title == "Quiet" }?.state == .off)
    #expect(menu5.items.first { $0.title == "Aware" }?.state == .off)
  }
}
