import Foundation
import CoreBluetooth

struct FoundGlasses: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

enum JarvisBLEError: LocalizedError {
    case noSavedGlasses
    case glassesUnavailable
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case bluetoothOff
    case timeout
    case connectFailed
    case disconnected
    case controlServiceMissing
    case writeCharacteristicMissing

    var errorDescription: String? {
        switch self {
        case .noSavedGlasses: return "Select your glasses first"
        case .glassesUnavailable: return "Saved glasses are not available"
        case .bluetoothUnauthorized: return "Bluetooth permission is not allowed"
        case .bluetoothUnsupported: return "Bluetooth is not supported"
        case .bluetoothOff: return "Bluetooth is off"
        case .timeout: return "Bluetooth connection timed out"
        case .connectFailed: return "Could not connect to the glasses"
        case .disconnected: return "The glasses disconnected"
        case .controlServiceMissing: return "M02S control service was not found"
        case .writeCharacteristicMissing: return "M02S write characteristic was not found"
        }
    }
}

final class BLEController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEController()

    // Confirmed M02S BLE path from the working v1 app/capture.
    private let controlService = CBUUID(string: "DE5BF728-D711-4E47-AF26-65E3012A5DC7")
    private let writeCharacteristicUUID = CBUUID(string: "DE5BF72A-D711-4E47-AF26-65E3012A5DC7")
    private let wakePacket = Data(hexString: "BC4103009052020107")!

    @Published var status: String = "Starting Bluetooth..."
    @Published var devices: [FoundGlasses] = []
    @Published var selectedName: String = UserDefaults.standard.string(forKey: "jarvis.glasses.name") ?? "Not selected"
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var autoReconnect: Bool = UserDefaults.standard.object(forKey: "jarvis.autoReconnect") as? Bool ?? true
    @Published var lastWakeText: String = "Never"

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingWake = false
    private var wakeContinuation: CheckedContinuation<Void, Error>?
    private var powerContinuation: CheckedContinuation<Void, Error>?
    private var reconnectWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.nexer.jarvisglasses.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    var savedPeripheralID: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: "jarvis.glasses.id") else { return nil }
        return UUID(uuidString: raw)
    }

    func setAutoReconnect(_ value: Bool) {
        autoReconnect = value
        UserDefaults.standard.set(value, forKey: "jarvis.autoReconnect")
        if value { reconnectSavedGlasses() }
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "Turn Bluetooth on"
            return
        }
        devices.removeAll()
        peripherals.removeAll()
        isScanning = true
        status = "Scanning for glasses..."
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.isScanning else { return }
            self.stopScan()
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        status = devices.isEmpty ? "No BLE devices found. Make sure the glasses are on." : "Pick your M02S below"
    }

    func select(_ device: FoundGlasses) {
        guard let peripheral = peripherals[device.id] else { return }
        UserDefaults.standard.set(device.id.uuidString, forKey: "jarvis.glasses.id")
        UserDefaults.standard.set(device.name, forKey: "jarvis.glasses.name")
        selectedName = device.name
        activePeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        isScanning = false
        status = "Connecting to \(device.name)..."
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func reconnectSavedGlasses() {
        guard central.state == .poweredOn,
              autoReconnect,
              let id = savedPeripheralID else { return }

        if let activePeripheral, activePeripheral.state == .connected {
            if writeCharacteristic == nil {
                activePeripheral.delegate = self
                activePeripheral.discoverServices([controlService])
            }
            return
        }

        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            status = "Saved glasses not found yet"
            return
        }

        activePeripheral = peripheral
        peripheral.delegate = self
        status = "Reconnecting to \(selectedName)..."
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func testWake() {
        Task {
            do {
                try await wakeSavedGlasses()
                await MainActor.run {
                    self.status = "Hey Jarvis wake sent ✓"
                    self.lastWakeText = Self.timeFormatter.string(from: Date())
                }
            } catch {
                await MainActor.run { self.status = "Wake failed: \(error.localizedDescription)" }
            }
        }
    }

    func wakeSavedGlasses() async throws {
        try await waitForBluetooth()

        if let peripheral = activePeripheral, peripheral.state == .connected {
            if let characteristic = writeCharacteristic {
                peripheral.writeValue(wakePacket, for: characteristic, type: .withoutResponse)
                await MainActor.run {
                    self.lastWakeText = Self.timeFormatter.string(from: Date())
                }
                return
            }

            pendingWake = true
            peripheral.delegate = self
            peripheral.discoverServices([controlService])
            try await waitForWakeCompletion(peripheral: peripheral)
            return
        }

        guard let id = savedPeripheralID else { throw JarvisBLEError.noSavedGlasses }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw JarvisBLEError.glassesUnavailable
        }

        activePeripheral = peripheral
        peripheral.delegate = self
        pendingWake = true
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        try await waitForWakeCompletion(peripheral: peripheral)
    }

    private func waitForWakeCompletion(peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            wakeContinuation = continuation

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak peripheral] in
                guard let self, let continuation = self.wakeContinuation else { return }
                self.wakeContinuation = nil
                self.pendingWake = false
                if let peripheral, peripheral.state != .connected {
                    self.central.cancelPeripheralConnection(peripheral)
                }
                continuation.resume(throwing: JarvisBLEError.timeout)
            }
        }
    }

    private func waitForBluetooth() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unauthorized { throw JarvisBLEError.bluetoothUnauthorized }
        if central.state == .unsupported { throw JarvisBLEError.bluetoothUnsupported }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            powerContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let continuation = self.powerContinuation else { return }
                self.powerContinuation = nil
                continuation.resume(throwing: JarvisBLEError.bluetoothOff)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            status = "Bluetooth ready"
            if let continuation = powerContinuation {
                powerContinuation = nil
                continuation.resume()
            }
            if autoReconnect {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.reconnectSavedGlasses()
                }
            }
        } else if central.state == .poweredOff {
            status = "Bluetooth is off"
            isConnected = false
        } else if central.state == .unauthorized {
            status = "Bluetooth permission denied"
            isConnected = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "BLE Device"
        peripherals[peripheral.identifier] = peripheral

        let item = FoundGlasses(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
        }

        devices.sort { lhs, rhs in
            let lGlasses = Self.looksLikeGlasses(lhs.name)
            let rGlasses = Self.looksLikeGlasses(rhs.name)
            if lGlasses != rGlasses { return lGlasses }
            return lhs.rssi > rhs.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        isConnected = true
        status = "Connected. Finding M02S control service..."
        peripheral.discoverServices([controlService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        finishWake(error: error ?? JarvisBLEError.connectFailed)
        status = "Connection failed"
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime,
                        isReconnecting: Bool,
                        error: Error?) {
        handleDisconnect(peripheral, error: error)
    }

    // Kept for compatibility with older SDK callback shape.
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        handleDisconnect(peripheral, error: error)
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        writeCharacteristic = nil
        if pendingWake {
            finishWake(error: error ?? JarvisBLEError.disconnected)
        }
        status = "Glasses disconnected"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard autoReconnect, savedPeripheralID != nil else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconnectSavedGlasses() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishWake(error: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == controlService }) else {
            finishWake(error: JarvisBLEError.controlServiceMissing)
            status = "Connected, but M02S control service was not found"
            return
        }
        peripheral.discoverCharacteristics([writeCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            finishWake(error: error)
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == writeCharacteristicUUID }) else {
            finishWake(error: JarvisBLEError.writeCharacteristicMissing)
            return
        }

        writeCharacteristic = characteristic
        isConnected = true
        status = "M02S ready ✓"

        if pendingWake {
            peripheral.writeValue(wakePacket, for: characteristic, type: .withoutResponse)
            pendingWake = false
            lastWakeText = Self.timeFormatter.string(from: Date())
            if let continuation = wakeContinuation {
                wakeContinuation = nil
                continuation.resume()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let saved = savedPeripheralID,
           let peripheral = restored.first(where: { $0.identifier == saved }) {
            activePeripheral = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                isConnected = true
                status = "Restored glasses connection"
                peripheral.discoverServices([controlService])
            }
        }
    }

    private func finishWake(error: Error) {
        pendingWake = false
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    private static func looksLikeGlasses(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("m02") || n.contains("m01") || n.contains("cyan") || n.contains("glasses")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()
}

extension Data {
    init?(hexString: String) {
        let clean = hexString.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
