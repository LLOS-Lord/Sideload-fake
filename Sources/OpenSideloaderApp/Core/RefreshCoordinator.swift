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
        let resigned = try await appSigning.resign(app: app)
        let installed = try await appInstalling.install(ipaURL: URL(fileURLWithPath: "/dev/null"))
        // Lưu ý: trong triển khai thật, `resign(app:)` nên trả về đường dẫn ipa
        // đã ký lại, và bạn truyền đúng URL đó vào `install(ipaURL:)` thay vì
        // placeholder ở trên. Để nguyên kiểu này giúp file compile độc lập
        // trước khi bạn nối MinimuxerBridge/AppleAuthAdapter thật.
        _ = installed
        return resigned
    }
}
