import Foundation
@preconcurrency import IOBluetooth

public struct DiscoveredBoseDevice: Sendable {
    public let device: IOBluetoothDevice
    public let channelID: BluetoothRFCOMMChannelID
    public let usesDirectCNC: Bool
    public let profile: DeviceProfile?

    public init(
        device: IOBluetoothDevice,
        channelID: BluetoothRFCOMMChannelID,
        usesDirectCNC: Bool,
        profile: DeviceProfile? = nil
    ) {
        self.device = device
        self.channelID = channelID
        self.usesDirectCNC = usesDirectCNC
        self.profile = profile
    }
}

public enum BoseDiscovery {
    public static func findDevice(log: ((String) -> Void)? = nil) -> DiscoveredBoseDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log?("No paired devices found")
            return nil
        }

        let defaults = UserDefaults.standard
        let savedAddr = defaults.string(forKey: "lastBoseDeviceAddress")
        let savedChannel = UInt8(defaults.integer(forKey: "lastBoseChannelID"))
        let savedDirectCNC = defaults.bool(forKey: "lastBoseDirectCNC")

        // 1. Fast-Path: if last-used Bose device is currently connected, use it instantly (0 ms)
        if let addr = savedAddr, let dev = IOBluetoothDevice(addressString: addr), dev.isConnected() {
            let ch: BluetoothRFCOMMChannelID = savedChannel > 0 ? savedChannel : (savedDirectCNC ? 9 : 2)
            log?("⚡ Fast-path connect to saved device: \(dev.name ?? addr) [\(addr)] ch=\(ch) directCNC=\(savedDirectCNC)")
            return DiscoveredBoseDevice(device: dev, channelID: ch, usesDirectCNC: savedDirectCNC)
        }

        log?("Scanning \(paired.count) paired devices...")

        // 2. Read persistent ports from Bluetooth plist (<1 ms)
        var persistentChannels: [String: BluetoothRFCOMMChannelID] = [:]
        if let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist"),
           let ports = plist["PersistentPorts"] as? [String: [String: Any]] {
            for (mac, info) in ports {
                if let ch = info["RFCOMMChannel"] as? NSNumber {
                    persistentChannels[mac.lowercased()] = ch.uint8Value
                }
            }
        }

        var candidates: [(IOBluetoothDevice, BluetoothRFCOMMChannelID, Bool, DeviceProfile?, Bool)] = []

        for dev in paired {
            let name = dev.name ?? ""
            let addr = dev.addressString?.lowercased() ?? ""
            var isBose = false
            var chID: BluetoothRFCOMMChannelID = persistentChannels[addr] ?? 2
            var directCNC = false
            var matchedProfile: DeviceProfile? = nil

            if chID == 9 {
                isBose = true
                directCNC = true
            }

            if let services = dev.services as? [IOBluetoothSDPServiceRecord] {
                for s in services {
                    if let sName = s.getServiceName(), sName == "SPP Dev" {
                        var c: BluetoothRFCOMMChannelID = 0
                        if s.getRFCOMMChannelID(&c) == kIOReturnSuccess {
                            chID = c
                            isBose = true
                        }
                    }
                    if let attrs = s.attributes {
                        for (k, v) in attrs {
                            guard let num = k as? NSNumber else { continue }
                            if num.uint32Value == 0x0201 { // VendorID
                                if let elem = v as? IOBluetoothSDPDataElement, elem.getNumberValue()?.uint16Value == DeviceCatalog.boseVendorID {
                                    isBose = true
                                }
                            }
                            if num.uint32Value == 0x0202 { // ProductID
                                if let elem = v as? IOBluetoothSDPDataElement, let pid = elem.getNumberValue()?.uint16Value {
                                    if let p = DeviceCatalog.profile(forProductID: pid) {
                                        matchedProfile = p
                                        chID = p.defaultChannelID
                                        directCNC = p.usesDirectCNC
                                        isBose = true
                                    } else if pid == 0x4024 {
                                        isBose = true
                                        chID = 9
                                        directCNC = true
                                    }
                                }
                            }
                            if num.uint32Value == 0x0001 {
                                let desc = String(describing: v)
                                if desc.contains("de ca fa de") || desc.contains("decafade") {
                                    isBose = true
                                }
                            }
                        }
                    }
                }
            }

            if !isBose {
                let matches = DeviceCatalog.knownNamePatterns.contains { name.localizedCaseInsensitiveContains($0) }
                if matches {
                    isBose = true
                    if name.localizedCaseInsensitiveContains("700") {
                        chID = 9
                        directCNC = true
                    }
                }
            }

            if isBose {
                log?("  Candidate: \(name) [\(dev.addressString ?? "?")] ch=\(chID) directCNC=\(directCNC) connected=\(dev.isConnected())")
                candidates.append((dev, chID, directCNC, matchedProfile, dev.isConnected()))
            }
        }

        // 3. Fallback: query system_profiler if no candidates found in cache
        if candidates.isEmpty {
            log?("No candidates in SDP cache, querying system_profiler...")
            for info in queryBoseDevicesFromSystem() {
                if let dev = IOBluetoothDevice(addressString: info.mac) {
                    let is700 = info.pid.localizedCaseInsensitiveContains("0x4024") || info.name.localizedCaseInsensitiveContains("700")
                    let chID: BluetoothRFCOMMChannelID = persistentChannels[info.mac.lowercased()] ?? (is700 ? 9 : 2)
                    log?("  Candidate (system_profiler): \(dev.name ?? info.name) [\(info.mac)] ch=\(chID) directCNC=\(is700) connected=\(info.isConnected)")
                    candidates.append((dev, chID, is700, nil, info.isConnected))
                }
            }
        }

        // Return first connected candidate, or first candidate
        if let conn = candidates.first(where: { $0.4 }) {
            return DiscoveredBoseDevice(device: conn.0, channelID: conn.1, usesDirectCNC: conn.2, profile: conn.3)
        }
        if let first = candidates.first {
            return DiscoveredBoseDevice(device: first.0, channelID: first.1, usesDirectCNC: first.2, profile: first.3)
        }
        return nil
    }

    private static func queryBoseDevicesFromSystem() -> [(mac: String, name: String, isConnected: Bool, pid: String)] {
        let pipe = Pipe()
        let proc = Process()
        proc.launchPath = "/usr/sbin/system_profiler"
        proc.arguments = ["SPBluetoothDataType", "-json"]
        proc.standardOutput = pipe
        proc.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        var results: [(String, String, Bool, String)] = []
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spList = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = spList.first else { return [] }

        if let conn = first["device_connected"] as? [[String: [String: Any]]] {
            for dict in conn {
                for (name, info) in dict {
                    let vid = info["device_vendorID"] as? String ?? ""
                    let pid = info["device_productID"] as? String ?? ""
                    let addr = info["device_address"] as? String ?? ""
                    if vid.localizedCaseInsensitiveContains("0x009E") {
                        results.append((addr, name, true, pid))
                    }
                }
            }
        }
        if let notConn = first["device_not_connected"] as? [[String: [String: Any]]] {
            for dict in notConn {
                for (name, info) in dict {
                    let vid = info["device_vendorID"] as? String ?? ""
                    let pid = info["device_productID"] as? String ?? ""
                    let addr = info["device_address"] as? String ?? ""
                    if vid.localizedCaseInsensitiveContains("0x009E") {
                        results.append((addr, name, false, pid))
                    }
                }
            }
        }
        return results
    }
}
