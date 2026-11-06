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
}
