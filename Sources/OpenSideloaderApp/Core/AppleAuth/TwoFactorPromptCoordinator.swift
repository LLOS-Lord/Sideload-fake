import Foundation

/// Cầu nối giữa `AppleGSAClient` (chạy trong Task nền, không biết gì về
/// SwiftUI) và 1 sheet thật hỏi mã 2FA. Dùng `CheckedContinuation` để
/// `requestCode` "treo" cho tới khi người dùng bấm Xong/Huỷ trên sheet — đây
/// là cách chuẩn (không polling, không timer) để cầu nối 1 async function với
/// 1 tương tác UI cần chờ người dùng.
@MainActor
final class TwoFactorPromptCoordinator: ObservableObject, TwoFactorCodeProviding {

    struct PendingRequest: Identifiable {
        let id = UUID()
        /// "trustedDevice" hoặc "sms" — khớp giá trị AppleGSAClient truyền vào.
        let method: String
    }

    @Published var pendingRequest: PendingRequest?
    private var continuation: CheckedContinuation<String?, Never>?

    /// Gọi từ AppleGSAClient (background) — tự động nhảy sang MainActor nhờ
    /// class này được đánh dấu `@MainActor`, không cần Task{ @MainActor } thủ công.
    func requestCode(method: String) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pendingRequest = PendingRequest(method: method)
        }
    }

    /// Gọi từ sheet khi người dùng nhập xong mã.
    func submit(code: String) {
        pendingRequest = nil
        continuation?.resume(returning: code)
        continuation = nil
    }

    /// Gọi từ sheet khi người dùng bấm Huỷ — luồng đăng nhập sẽ nhận `nil` và
    /// tự báo lỗi "cần mã 2FA" thay vì treo vô thời hạn.
    func cancel() {
        pendingRequest = nil
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
