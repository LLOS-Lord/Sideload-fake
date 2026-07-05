import SwiftUI

/// Entry point của bản UI rút gọn.
///
/// Lưu ý: `AppEnvironment` bên dưới nắm giữ các adapter nối vào AppleAuthAdapter/MinimuxerFFI thật.
/// Bạn khởi tạo nó một lần ở đây, sau đó truyền xuống toàn bộ view qua
/// `.environmentObject`, để mọi màn hình dùng chung một nguồn dữ liệu và
/// không phải tự quản lý kết nối thiết bị/VPN riêng lẻ.
@main
struct OpenSideloaderApp: App {

    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
                .task {
                    await environment.bootstrap()
                }
        }
    }
}

/// Gói toàn bộ trạng thái toàn cục: danh sách app đã sideload, trạng thái VPN,
/// trạng thái đăng nhập Apple ID, và các adapter thao tác với DeveloperServicesAPI/MinimuxerFFI.
///
/// Đây là nơi DUY NHẤT nên giữ tham chiếu tới các adapter thật (AppleAuthAdapter,
/// MinimuxerDeviceAdapter), để phần UI phía dưới hoàn toàn không cần biết chi tiết
/// kỹ thuật của minimuxer/AppleAuthAdapter/StosVPN — chỉ gọi qua các protocol trong CoreProtocols.swift.
@MainActor
final class AppEnvironment: ObservableObject {

    @Published var installedApps: [SideloadedApp] = []
    @Published var vpnStatus: VPNStatus = .unknown
    @Published var appleAccountEmail: String?
    @Published var lastError: FriendlyError?
    @Published var isBusy: Bool = false

    // Các adapter này cần được implement thật, xem CoreProtocols.swift.
    let deviceConnection: DeviceConnecting
    let appSigning: AppSigning
    let appInstalling: AppInstalling
    let pairingFileManaging: PairingFileManaging

    let refreshCoordinator: RefreshCoordinator

    init(
        deviceConnection: DeviceConnecting = MinimuxerDeviceAdapter(),
        appSigning: AppSigning = AppleAuthAdapter(),
        appInstalling: AppInstalling = MinimuxerDeviceAdapter(),
        pairingFileManaging: PairingFileManaging = MinimuxerDeviceAdapter()
    ) {
        self.deviceConnection = deviceConnection
        self.appSigning = appSigning
        self.appInstalling = appInstalling
        self.pairingFileManaging = pairingFileManaging
        self.refreshCoordinator = RefreshCoordinator(
            appSigning: appSigning,
            appInstalling: appInstalling
        )
    }

    /// Gọi khi app khởi động: kiểm tra VPN, nạp danh sách app đã cài, lên lịch refresh nền.
    func bootstrap() async {
        isBusy = true
        defer { isBusy = false }

        vpnStatus = await deviceConnection.currentVPNStatus()

        do {
            installedApps = try await appInstalling.fetchInstalledApps()
        } catch {
            lastError = FriendlyError(from: error)
        }

        refreshCoordinator.scheduleBackgroundRefresh(for: installedApps) { [weak self] result in
            Task { @MainActor in
                self?.handle(result)
            }
        }
    }

    func handle(_ result: RefreshResult) {
        switch result {
        case .success(let updatedApp):
            if let index = installedApps.firstIndex(where: { $0.id == updatedApp.id }) {
                installedApps[index] = updatedApp
            }
        case .failure(let app, let error):
            lastError = FriendlyError(from: error, context: .refreshingApp(app.name))
        }
    }

    /// Nút "Sửa lỗi kết nối" trong Settings gọi thẳng vào đây.
    func repairPairingAndVPN() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await pairingFileManaging.resetPairingFile()
            try await pairingFileManaging.requestFreshPairingFile()
            vpnStatus = await deviceConnection.currentVPNStatus()
            lastError = nil
        } catch {
            lastError = FriendlyError(from: error, context: .repairingConnection)
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            MyAppsView()
                .tabItem { Label("Ứng dụng", systemImage: "square.grid.2x2") }

            InstallView()
                .tabItem { Label("Cài đặt mới", systemImage: "plus.app") }

            SettingsView()
                .tabItem { Label("Cài đặt hệ thống", systemImage: "gearshape") }
        }
    }
}
