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
/// Triển khai thật: MinimuxerDeviceAdapter, tương đương idevice_pair (jkcoxson/idevice_pair).
protocol PairingFileManaging {
    func resetPairingFile() async throws
    func requestFreshPairingFile() async throws
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
    func resetPairingFile() async throws {
        throw NotWiredUpError.adapterNotImplemented("PairingFileManaging")
    }
    func requestFreshPairingFile() async throws {
        throw NotWiredUpError.adapterNotImplemented("PairingFileManaging")
    }
}
