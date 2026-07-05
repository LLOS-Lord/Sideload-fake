import Foundation

/// Lên lịch và thực thi việc "làm mới" (re-sign + reinstall) các app trước khi
/// provisioning profile (thường 7 ngày với tài khoản Apple ID miễn phí) hết hạn.
///
/// Thiết kế đơn giản hơn SideStore ở điểm: chỉ MỘT coordinator, MỘT policy
/// (refresh trước hạn 24h), thay vì để người dùng tự cấu hình nhiều tuỳ chọn.
/// Có thể mở rộng thêm tuỳ chọn sau nếu thật sự cần.
actor RefreshCoordinator {

    private let appSigning: AppSigning
    private let appInstalling: AppInstalling
    private let refreshBeforeExpiry: TimeInterval = 24 * 60 * 60 // 24 giờ

    init(appSigning: AppSigning, appInstalling: AppInstalling) {
        self.appSigning = appSigning
        self.appInstalling = appInstalling
    }

    /// Gọi một lần khi app khởi động hoặc khi vào foreground.
    /// `onResult` được gọi trên mỗi app xử lý xong (thành công hoặc lỗi).
    nonisolated func scheduleBackgroundRefresh(
        for apps: [SideloadedApp],
        onResult: @escaping (RefreshResult) -> Void
    ) {
        Task {
            await self.runRefreshPass(for: apps, onResult: onResult)
        }
    }

    private func runRefreshPass(
        for apps: [SideloadedApp],
        onResult: @escaping (RefreshResult) -> Void
    ) async {
        let dueApps = apps.filter { app in
            app.expirationDate.timeIntervalSinceNow < refreshBeforeExpiry
        }

        for app in dueApps {
            do {
                let refreshed = try await refreshOne(app)
                onResult(.success(refreshed))
            } catch {
                onResult(.failure(app, error))
            }
        }
    }

    /// Refresh thủ công khi người dùng bấm nút "Làm mới" trên một app cụ thể.
    func refreshNow(_ app: SideloadedApp) async throws -> SideloadedApp {
        try await refreshOne(app)
    }

    private func refreshOne(_ app: SideloadedApp) async throws -> SideloadedApp {
        // resign() trả về app với localIpaPath TRỎ TỚI bản .ipa đã ký lại
        // (xem AppleAuthAdapter.resign) — cài lại đúng file đó, không phải
        // file gốc lúc cài lần đầu.
        let resigned = try await appSigning.resign(app: app)
        let signedURL = URL(fileURLWithPath: resigned.localIpaPath)
        return try await appInstalling.install(ipaURL: signedURL)
    }
}
