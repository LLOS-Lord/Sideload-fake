import Foundation
import MinimuxerFFI

/// Triển khai thật của `DeviceConnecting`, `AppInstalling`, `PairingFileManaging`
/// gọi vào `MinimuxerFFI` (binary target khai báo trong Package.swift, build từ
/// https://github.com/SideStore/minimuxer hoặc https://github.com/jkcoxson/minimuxer
/// — dùng như dependency biên dịch sẵn, không copy mã nguồn Rust vào repo này).
///
/// Ghi chú độ tin cậy: minimuxer dùng crate `swift-bridge` để sinh API Swift từ
/// Rust. Đã xác nhận được: có kiểu lỗi `Errors` (bridge sang Swift là
/// `MinimuxerError`), có hàm dạng `install_provisioning_profile(profile: &[u8])`,
/// và có case lỗi `InstallApp(String)` cho luồng cài ipa. TÊN HÀM CHÍNH XÁC (viết
/// hoa/thường, tham số) cần đối chiếu với file `.swift`/`.h` mà swift-bridge sinh
/// ra — sau khi thêm binaryTarget vào Xcode, mở "MinimuxerFFI" trong Project
/// Navigator để xem interface thật, rồi sửa các lời gọi bên dưới cho khớp. Xcode
/// sẽ báo lỗi biên dịch rõ ràng ở đúng chỗ cần sửa nếu tên chưa khớp.
final class MinimuxerDeviceAdapter: DeviceConnecting, AppInstalling, PairingFileManaging {

    private let pairingFileStore = PairingFileStore()

    // MARK: DeviceConnecting

    func currentVPNStatus() async -> VPNStatus {
        // Kiểm tra trạng thái NEVPNManager của cấu hình StosVPN (app VPN cài
        // riêng, xem README mục 3) — đây là API chuẩn của Apple, không thuộc
        // MinimuxerFFI.
        let manager = await NEVPNStatusReader.currentStosVPNManager()
        switch manager?.connection.status {
        case .connected:
            return .connected(deviceIP: "10.7.0.1") // đổi theo IP thật trong config StosVPN
        case .disconnected, .invalid, .none:
            return .disconnected
        default:
            return .unknown
        }
    }

    // MARK: AppInstalling

    func fetchInstalledApps() async throws -> [SideloadedApp] {
        // TODO: gọi hàm liệt kê app đã cài qua installation_proxy — tương ứng
        // phía Rust là danh sách app trong instproxy client. Tên hàm Swift thật
        // sau khi bridge cần lấy từ interface MinimuxerFFI (xem ghi chú đầu file).
        []
    }

    func install(ipaURL: URL) async throws -> SideloadedApp {
        let ipaData = try Data(contentsOf: ipaURL)
        do {
            // Tên hàm minh hoạ theo pattern install_ipa/installApp mà minimuxer
            // dùng nội bộ (xem "InstallApp(String)" trong Errors enum) — XÁC MINH
            // lại tên thật trước khi build.
            try await MinimuxerBridge.installApp(ipaData: ipaData)
        } catch {
            throw error
        }
        return SideloadedApp(
            id: UUID().uuidString,
            name: ipaURL.deletingPathExtension().lastPathComponent,
            version: "1.0",
            iconSystemName: "app.badge",
            installedDate: Date(),
            expirationDate: Date().addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    func uninstall(app: SideloadedApp) async throws {
        try await MinimuxerBridge.uninstallApp(bundleID: app.id)
    }

    // MARK: PairingFileManaging — luồng sửa lỗi AFC trực tiếp

    func resetPairingFile() async throws {
        try pairingFileStore.deleteStoredPairingFile()
    }

    func requestFreshPairingFile() async throws {
        // Tương đương idevice_pair (https://github.com/jkcoxson/idevice_pair):
        // tạo pairing record mới trực tiếp với thiết bị đang chạy app này.
        let newPairingFile = try await MinimuxerBridge.generatePairingFile()
        try pairingFileStore.save(newPairingFile)
    }
}

/// Lưu/xoá pairing file trong Keychain — đây là nguyên nhân phổ biến nhất của
/// lỗi "AFC was unable to manage files", nên tách riêng thành 1 type rõ ràng,
/// dễ test độc lập, thay vì giấu trong luồng cài đặt chung như bản gốc.
struct PairingFileStore {
    private let keychainKey = "com.opensideloader.pairingfile"

    func save(_ data: Data) throws {
        // TODO: lưu vào Keychain (kSecClassGenericPassword) thay vì UserDefaults
        // để tránh rò rỉ khi backup không mã hoá.
    }

    func deleteStoredPairingFile() throws {
        // TODO: xoá entry Keychain tương ứng `keychainKey`.
    }
}

/// Bọc lại NEVPNManager để phần còn lại của app không cần biết chi tiết
/// NetworkExtension.
enum NEVPNStatusReader {
    static func currentStosVPNManager() async -> NEVPNManagerReadable? {
        // TODO: load NETunnelProviderManager tương ứng cấu hình StosVPN đã cài,
        // dùng NETunnelProviderManager.loadAllFromPreferences().
        nil
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
