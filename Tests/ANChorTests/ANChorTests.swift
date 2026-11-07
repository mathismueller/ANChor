import AppKit
import XCTest

@testable import ANChor
@testable import BoseKit

@MainActor
final class ANChorTests: XCTestCase {

  func testDisconnectedMenuStructure() {
    let device = BoseDevice()
    // Default device is disconnected
    let menu = MenuBuilder.buildMenu(device: device, delegate: nil)

    // Must have device name header
    XCTAssertEqual(menu.items.first?.title, device.deviceName)

    // Must show "Not connected"
    let titles = menu.items.map { $0.title }
    XCTAssertTrue(titles.contains("Not connected"))
    XCTAssertTrue(titles.contains("Reconnect"))
    XCTAssertTrue(titles.contains("Start at Login"))

    let loginItem = menu.items.first(where: { $0.title == "Start at Login" })
    XCTAssertNotNil(loginItem)
    XCTAssertEqual(loginItem?.action, #selector(AppDelegate.toggleStartAtLogin))
    XCTAssertEqual(loginItem?.state, .off)

    let menuEnabled = MenuBuilder.buildMenu(device: device, delegate: nil, startAtLogin: true)
    let loginItemEnabled = menuEnabled.items.first(where: { $0.title == "Start at Login" })
    XCTAssertEqual(loginItemEnabled?.state, .on)

    // Must have standard quit item
    let quitItem = menu.items.first(where: { $0.title == "Quit ANChor" })
    XCTAssertNotNil(quitItem)
    XCTAssertEqual(quitItem?.action, #selector(AppDelegate.quit))
    XCTAssertEqual(quitItem?.keyEquivalent, "q")
  }

  func testFormatDB() {
    XCTAssertEqual(MenuBuilder.formatDB(0), "0 dB")
    XCTAssertEqual(MenuBuilder.formatDB(4), "+4 dB")
    XCTAssertEqual(MenuBuilder.formatDB(-3), "-3 dB")
  }

  func testBatterySymbolMapping() {
    XCTAssertEqual(MenuBuilder.batterySymbol(forPercent: 100), "battery.100")
    XCTAssertEqual(MenuBuilder.batterySymbol(forPercent: 85), "battery.75")
    XCTAssertEqual(MenuBuilder.batterySymbol(forPercent: 50), "battery.50")
    XCTAssertEqual(MenuBuilder.batterySymbol(forPercent: 25), "battery.25")
    XCTAssertEqual(MenuBuilder.batterySymbol(forPercent: 10), "battery.0")
  }

  func testVolumeSliderItemCreation() {
    let item = MenuBuilder.createVolumeSliderItem(current: 8, max: 16, delegate: nil)
    XCTAssertNotNil(item.view)
    let subviews = item.view?.subviews ?? []
    XCTAssertEqual(subviews.count, 3)

    let slider = subviews.compactMap { $0 as? NSSlider }.first
    XCTAssertNotNil(slider)
    XCTAssertEqual(slider?.doubleValue, 8.0)
    XCTAssertEqual(slider?.maxValue, 16.0)

    let label = item.view?.viewWithTag(99) as? NSTextField
    XCTAssertNotNil(label)
    XCTAssertEqual(label?.stringValue, "50%")
  }

  func testNoiseLevelSliderItemCreation() {
    let item = MenuBuilder.createNoiseLevelSliderItem(current: 5, delegate: nil)
    XCTAssertNotNil(item.view)
    let subviews = item.view?.subviews ?? []
    XCTAssertEqual(subviews.count, 3)

    let slider = subviews.compactMap { $0 as? NSSlider }.first
    XCTAssertNotNil(slider)
    XCTAssertEqual(slider?.doubleValue, 5.0)
    XCTAssertEqual(slider?.maxValue, 10.0)
    XCTAssertEqual(slider?.numberOfTickMarks, 11)
    XCTAssertEqual(slider?.allowsTickMarkValuesOnly, true)

    let label = item.view?.viewWithTag(99) as? NSTextField
    XCTAssertNotNil(label)
    XCTAssertEqual(label?.stringValue, "Level 5")
  }

  func testListeningModeCheckedOnlyAtRespectiveLevels() {
    let device = BoseDevice()
    device.setConnectedForTesting(true)
    device.setDirectCNCForTesting(true)

    // At Level 0: Quiet is ON, Aware is OFF
    device.setCNCLevel(0)
    let menu0 = MenuBuilder.buildMenu(device: device, delegate: nil)
    let quiet0 = menu0.items.first(where: { $0.title == "Quiet" })
    let aware0 = menu0.items.first(where: { $0.title == "Aware" })
    XCTAssertEqual(quiet0?.state, .on)
    XCTAssertEqual(aware0?.state, .off)

    // At Level 10: Quiet is OFF, Aware is ON
    device.setCNCLevel(10)
    let menu10 = MenuBuilder.buildMenu(device: device, delegate: nil)
    let quiet10 = menu10.items.first(where: { $0.title == "Quiet" })
    let aware10 = menu10.items.first(where: { $0.title == "Aware" })
    XCTAssertEqual(quiet10?.state, .off)
    XCTAssertEqual(aware10?.state, .on)

    // At intermediate Level 5: BOTH Quiet and Aware are OFF
    device.setCNCLevel(5)
    let menu5 = MenuBuilder.buildMenu(device: device, delegate: nil)
    let quiet5 = menu5.items.first(where: { $0.title == "Quiet" })
    let aware5 = menu5.items.first(where: { $0.title == "Aware" })
    XCTAssertEqual(quiet5?.state, .off)
    XCTAssertEqual(aware5?.state, .off)
  }
}
