import Foundation

/// Đại diện đơn giản cho một app đã sideload — do OpenSideloader tự định nghĩa,
/// map từ dữ liệu trả về bởi MinimuxerBridge (installation_proxy). Giữ struct
/// này nhẹ và value-type để UI dễ diff/animate khi danh sách cập nhật.
struct SideloadedApp: Identifiable, Equatable {
    let id: String                 // bundle identifier
    let name: String
    let version: String
    let iconSystemName: String     // placeholder; thực tế lấy icon thật từ ipa
    let installedDate: Date
    let expirationDate: Date       // ngày hết hạn provisioning profile (thường +7 ngày)

    var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
    }

    var expiryFraction: Double {
        let total = expirationDate.timeIntervalSince(installedDate)
        let elapsed = Date().timeIntervalSince(installedDate)
        guard total > 0 else { return 1 }
        return min(max(elapsed / total, 0), 1)
    }

    var isExpiringSoon: Bool { daysRemaining <= 1 }
}

enum RefreshResult {
    case success(SideloadedApp)
    case failure(SideloadedApp, Error)
}

enum VPNStatus: Equatable {
    case unknown
    case disconnected
    case connectedWrongNetwork   // ví dụ đang dùng 4G/5G thay vì Wi-Fi
    case connected(deviceIP: String)

    var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}
