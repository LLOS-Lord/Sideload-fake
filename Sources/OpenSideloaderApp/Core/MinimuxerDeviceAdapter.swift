import Foundation
import NetworkExtension
import Security
import Minimuxer

/// Triển khai thật của `DeviceConnecting`, `AppInstalling`, `PairingFileManaging`
/// gọi vào `Minimuxer` qua `MinimuxerBridge` (xem file đó để biết tên hàm
/// FFI thật đã xác nhận) + Keychain/NetworkExtension chuẩn của Apple.
final class MinimuxerDeviceAdapter: DeviceConnecting, AppInstalling, PairingFileManaging {

    private let pairingFileStore = PairingFileStore()
    private let installedAppsStore = InstalledAppsStore()
    private var muxerStarted = false

    // MARK: DeviceConnecting

    func currentVPNStatus() async -> VPNStatus {
        let manager = await NEVPNStatusReader.currentStosVPNManager()
        switch manager?.connection.status {
        case .connected:
            return .connected(deviceIP: "10.7.0.1") // IP loopback cố định minimuxer dùng, xác nhận từ src/muxer.rs
        case .disconnected, .invalid, .none:
            return .disconnected
        default:
            return .unknown
        }
    }

    // MARK: PairingFileManaging

    func hasValidPairingFile() async -> Bool {
        guard pairingFileStore.hasStoredPairingFile else { return false }
        do {
            try await ensureMuxerStarted()
            return MinimuxerBridge.testConnection()
        } catch {
            return false
        }
    }

    func resetPairingFile() async throws {
        try pairingFileStore.deleteStoredPairingFile()
        muxerStarted = false
    }

    func importPairingFile(from fileURL: URL) async throws {
        let needsSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { fileURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8),
              contents.contains("UDID") else {
            // Kiểm tra tối thiểu này đối chiếu đúng điều kiện `start()` của
            // minimuxer sẽ tự kiểm tra lại lần nữa (parse plist + đòi key
            // "UDID") — xác nhận từ src/muxer.rs.
            throw PairingFileError.missingUDIDKey
        }
        try pairingFileStore.save(data)
        muxerStarted = false
        try await ensureMuxerStarted()
    }

    /// Gọi 1 lần trước mọi thao tác AFC/install — an toàn khi gọi nhiều lần
    /// nhờ `STARTED` atomic bool phía Rust (start() tự no-op nếu đã chạy rồi,
    /// xác nhận từ src/muxer.rs).
    private func ensureMuxerStarted() async throws {
        guard !muxerStarted else { return }
        guard let pairingContents = pairingFileStore.loadStoredPairingFileContents() else {
            throw PairingFileError.noPairingFileStored
        }
        MinimuxerBridge.targetMinimuxerAddress()
        let logPath = "file://\(NSTemporaryDirectory())"
        try await MinimuxerBridge.startMuxer(pairingFileContents: pairingContents, logPath: logPath)
        muxerStarted = true
    }

    // MARK: AppInstalling

    func fetchInstalledApps() async throws -> [SideloadedApp] {
        // ⚠️ minimuxer KHÔNG expose hàm "liệt kê app đã cài" (đã rà toàn bộ
        // khối extern "Rust" trong install.rs/device.rs/provision.rs, không
        // có). Vậy nên OpenSideloader tự lưu danh sách app nó đã cài thành
        // công (InstalledAppsStore, UserDefaults) thay vì hỏi lại thiết bị —
        // đơn giản hơn nhưng đồng nghĩa: app cài bằng công cụ KHÁC (Xcode,
        // AltStore...) sẽ không hiện ở đây, chỉ app cài qua chính
        // OpenSideloader mới được theo dõi.
        installedAppsStore.loadAll()
    }

    func install(ipaURL: URL) async throws -> SideloadedApp {
        try await ensureMuxerStarted()

        let ipaData = try Data(contentsOf: ipaURL)
        let bundleID = try Self.readBundleIdentifier(fromIpaAt: ipaURL) ?? ipaURL.deletingPathExtension().lastPathComponent

        try await MinimuxerBridge.installApp(bundleID: bundleID, ipaData: ipaData)

        // Lưu 1 bản .ipa cố định trong Application Support — không dùng lại
        // URL tạm người dùng chọn (fileImporter cấp quyền security-scoped chỉ
        // có hiệu lực trong phiên chọn file đó), để refresh sau này còn có gì
        // đó để ký lại mà không phải hỏi lại người dùng chọn file mỗi 7 ngày.
        let localURL = try Self.persistentIpaStorageURL(bundleID: bundleID)
        try ipaData.write(to: localURL, options: .atomic)

        let app = SideloadedApp(
            id: bundleID,
            name: ipaURL.deletingPathExtension().lastPathComponent,
            version: "1.0",
            iconSystemName: "app.badge",
            installedDate: Date(),
            expirationDate: Date().addingTimeInterval(7 * 24 * 60 * 60),
            localIpaPath: localURL.path
        )
        installedAppsStore.upsert(app)
        return app
    }

    private static func persistentIpaStorageURL(bundleID: String) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = appSupport.appendingPathComponent("OpenSideloader/InstalledIPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(bundleID).ipa")
    }

    func uninstall(app: SideloadedApp) async throws {
        try await ensureMuxerStarted()
        try await MinimuxerBridge.uninstallApp(bundleID: app.id)
        installedAppsStore.remove(id: app.id)
    }

    /// Đọc CFBundleIdentifier từ Info.plist bên trong ipa (ipa là file zip có
    /// cấu trúc `Payload/<Tên>.app/Info.plist`) — cần để gọi installation_proxy
    /// đúng bundle id thay vì suy từ tên file, vốn có thể khác bundle id thật.
    private static func readBundleIdentifier(fromIpaAt url: URL) throws -> String? {
        do {
            return try BundleIdentifierReader.readBundleIdentifier(from: url.path)
        } catch {
            // Nếu lỗi (ví dụ: ZIPFoundation chưa được thêm), trả về nil
            // và sẽ dùng tên file làm fallback
            return nil
        }
    }
}

enum PairingFileError: LocalizedError {
    case missingUDIDKey
    case noPairingFileStored

    var errorDescription: String? {
        switch self {
        case .missingUDIDKey:
            return "File pairing không có key UDID — không phải file hợp lệ, hoặc bị hỏng khi copy."
        case .noPairingFileStored:
            return "Chưa có pairing file nào — vào Cài đặt → Sửa lỗi kết nối để nhập file."
        }
    }
}

/// Lưu/xoá pairing file trong Keychain — đây là nguyên nhân phổ biến nhất của
/// lỗi "AFC was unable to manage files", nên tách riêng thành 1 type rõ ràng,
/// dễ test độc lập, thay vì giấu trong luồng cài đặt chung như bản gốc.
///
/// Dùng Keychain (không phải UserDefaults) vì pairing file chứa private key —
/// lộ ra ngoài tương đương lộ quyền truy cập AFC/lockdown vào thiết bị.
struct PairingFileStore {
    private let service = "com.opensideloader.pairingfile"
    private let account = "default"

    var hasStoredPairingFile: Bool {
        loadStoredPairingFileContents() != nil
    }

    func save(_ data: Data) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary) // ghi đè sạch bản cũ nếu có

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status: status)
        }
    }

    func loadStoredPairingFileContents() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteStoredPairingFile() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Lưu Keychain thất bại (OSStatus \(status))."
        case .deleteFailed(let status): return "Xoá Keychain thất bại (OSStatus \(status))."
        }
    }
}

/// Lưu danh sách app OpenSideloader đã cài thành công — thay thế cho việc
/// minimuxer không hỗ trợ liệt kê app cài trên thiết bị (xem fetchInstalledApps()).
final class InstalledAppsStore {
    private let key = "com.opensideloader.installedapps"
    private let defaults = UserDefaults.standard

    func loadAll() -> [SideloadedApp] {
        guard let data = defaults.data(forKey: key),
              let apps = try? JSONDecoder().decode([SideloadedApp].self, from: data) else {
            return []
        }
        return apps
    }

    func upsert(_ app: SideloadedApp) {
        var all = loadAll().filter { $0.id != app.id }
        all.append(app)
        save(all)
    }

    func remove(id: String) {
        save(loadAll().filter { $0.id != id })
    }

    private func save(_ apps: [SideloadedApp]) {
        if let data = try? JSONEncoder().encode(apps) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Bọc lại NEVPNManager/NETunnelProviderManager để phần còn lại của app không
/// cần biết chi tiết NetworkExtension. Tìm đúng cấu hình StosVPN bằng
/// `localizedDescription` — StosVPN đặt tên cấu hình cố định khi cài, xem
/// README nếu tên khác đi ở bản bạn cài.
enum NEVPNStatusReader {
    static func currentStosVPNManager() async -> NEVPNManagerReadable? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            // StosVPN có thể là NETunnelProviderManager (packet-tunnel-provider)
            // HOẶC 1 cấu hình Personal VPN thường — nếu không tìm thấy theo tên,
            // rơi về manager đầu tiên đang enabled để không lỡ báo "chưa cài".
            let match = managers.first { $0.localizedDescription?.localizedCaseInsensitiveContains("stosvpn") == true }
                ?? managers.first { $0.isEnabled }
            guard let match else { return nil }
            return NETunnelManagerWrapper(manager: match)
        } catch {
            return nil
        }
    }
}

private struct NETunnelManagerWrapper: NEVPNManagerReadable {
    let manager: NETunnelProviderManager
    var connection: NEVPNConnectionReadable { NEVPNConnectionWrapper(connection: manager.connection) }
}

private struct NEVPNConnectionWrapper: NEVPNConnectionReadable {
    let connection: NEVPNConnection
    var status: NEVPNStatusValue {
        switch connection.status {
        case .connected: return .connected
        case .disconnected, .invalid: return .disconnected
        default: return .invalid
        }
    }
}

protocol NEVPNManagerReadable {
    var connection: NEVPNConnectionReadable { get }
}
protocol NEVPNConnectionReadable {
    var status: NEVPNStatusValue { get }
}
enum NEVPNStatusValue {
    case connected, disconnected, invalid
}
