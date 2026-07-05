import Foundation

// MARK: - Ranh giới giữa app OpenSideloader và các dependency bên ngoài
//
// Đây là project độc lập: các protocol dưới đây do OpenSideloader tự định nghĩa,
// KHÔNG copy từ SideStore/AltStore. Việc triển khai thật nằm ở
// AppleAuthAdapter.swift (thư mục AppleAuth/) và MinimuxerDeviceAdapter.swift,
// gọi vào swift-certificates/BigInt (SPM) và MinimuxerFFI (binary target) khai báo trong
// Package.swift — cả hai được dùng như dependency bên ngoài, y hệt cách bạn
// dùng bất kỳ package SPM nào khác.
//
// Các Placeholder* ở cuối file chỉ để project build/preview được khi CHƯA thêm
// dependency thật hoặc khi chạy trên máy không có thiết bị cắm vào.

/// Bọc thao tác liên quan tới VPN loopback (StosVPN) + minimuxer.
///
/// Triển khai thật: MinimuxerDeviceAdapter (đọc trạng thái NEVPNStatus của
/// cấu hình StosVPN đã cài riêng trên máy).
protocol DeviceConnecting {
    func currentVPNStatus() async -> VPNStatus
}

/// Bọc thao tác ký lại ipa bằng chứng chỉ + provisioning profile.
///
/// Triển khai thật: AppleAuthAdapter (thư mục Core/AppleAuth/) — đăng nhập
/// Apple ID qua GrandSlam/SRP (tự viết, xem AppleGSAClient.swift) + xin
/// certificate/provisioning profile qua DeveloperServicesAPI.swift. Bước ký
/// ipa cuối cùng vẫn là ranh giới TODO — xem IpaCodeSigning trong
/// AppleAuthAdapter.swift.
protocol AppSigning {
    func signIn(email: String, password: String) async throws
    func resign(app: SideloadedApp) async throws -> SideloadedApp
}

/// Bọc thao tác cài đặt / gỡ / liệt kê app qua AFC + installation_proxy.
///
/// Triển khai thật: MinimuxerDeviceAdapter, gọi vào MinimuxerFFI (AFC + installation_proxy).
protocol AppInstalling {
    func fetchInstalledApps() async throws -> [SideloadedApp]
    func install(ipaURL: URL) async throws -> SideloadedApp
    func uninstall(app: SideloadedApp) async throws
}

/// Bọc thao tác quản lý pairing file (nguồn gốc phổ biến nhất của lỗi AFC).
///
/// ⚠️ Đã xác nhận qua mã nguồn thật của minimuxer: KHÔNG có hàm FFI nào tự
/// "sinh" pairing file mới trên chính thiết bị — minimuxer chỉ TIÊU THỤ 1
/// pairing file có sẵn qua `start(pairing_file:log_path:)`. Vì vậy
/// `PairingFileManaging` ở đây là NHẬP (import) một file đã được tạo từ bên
/// ngoài (ví dụ bằng `make_pair_file.py` chạy trên Termux/PC qua USB thật —
/// xem README mục 3), không phải tự sinh trên máy.
protocol PairingFileManaging {
    /// Đã có pairing file lưu trong Keychain và minimuxer đã start thành công chưa.
    func hasValidPairingFile() async -> Bool
    /// Xoá pairing file cũ (bước đầu của quy trình sửa lỗi AFC).
    func resetPairingFile() async throws
    /// Nhập nội dung 1 file `.mobiledevicepairing`/`.plist` do người dùng chọn
    /// (qua UIDocumentPicker), lưu Keychain, rồi khởi động lại minimuxer với
    /// nó — bước còn lại của quy trình sửa lỗi AFC.
    func importPairingFile(from fileURL: URL) async throws
}

// MARK: - Placeholder implementations (dùng cho SwiftUI #Preview và Unit Test,
// KHÔNG dùng làm implementation mặc định của app thật — App.swift đã trỏ
// thẳng sang AppleAuthAdapter/MinimuxerDeviceAdapter).

struct PlaceholderDeviceConnection: DeviceConnecting {
    func currentVPNStatus() async -> VPNStatus { .unknown }
}

enum NotWiredUpError: LocalizedError {
    case adapterNotImplemented(String)
    var errorDescription: String? {
        switch self {
        case .adapterNotImplemented(let name):
            return "\(name) chưa được nối với AppleAuthAdapter/MinimuxerFFI thật. Xem README.md mục 4."
        }
    }
}

struct PlaceholderAppSigning: AppSigning {
    func signIn(email: String, password: String) async throws {
        throw NotWiredUpError.adapterNotImplemented("AppSigning")
    }
    func resign(app: SideloadedApp) async throws -> SideloadedApp {
        throw NotWiredUpError.adapterNotImplemented("AppSigning")
    }
}

struct PlaceholderAppInstalling: AppInstalling {
    func fetchInstalledApps() async throws -> [SideloadedApp] { [] }
    func install(ipaURL: URL) async throws -> SideloadedApp {
        throw NotWiredUpError.adapterNotImplemented("AppInstalling")
    }
    func uninstall(app: SideloadedApp) async throws {
        throw NotWiredUpError.adapterNotImplemented("AppInstalling")
    }
}

struct PlaceholderPairingFileManaging: PairingFileManaging {
    func hasValidPairingFile() async -> Bool { false }
    func resetPairingFile() async throws {
        throw NotWiredUpError.adapterNotImplemented("PairingFileManaging")
    }
    func importPairingFile(from fileURL: URL) async throws {
        throw NotWiredUpError.adapterNotImplemented("PairingFileManaging")
    }
}
