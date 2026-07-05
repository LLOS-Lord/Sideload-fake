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
                // Đưa riêng thành EnvironmentObject để SwiftUI observe đúng
                // @Published pendingRequest — binding xuyên qua 2 lớp
                // (environment.twoFactorCoordinator.pendingRequest) KHÔNG tự
                // kích hoạt refresh vì AppEnvironment không re-publish thay
                // đổi của object con.
                .environmentObject(environment.twoFactorCoordinator)
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
    /// Sheet hỏi mã 2FA bind vào biến này — xem RootTabView bên dưới.
    let twoFactorCoordinator: TwoFactorPromptCoordinator

    let refreshCoordinator: RefreshCoordinator

    init(
        deviceConnection: DeviceConnecting = MinimuxerDeviceAdapter(),
        appInstalling: AppInstalling = MinimuxerDeviceAdapter(),
        pairingFileManaging: PairingFileManaging = MinimuxerDeviceAdapter()
    ) {
        let coordinator = TwoFactorPromptCoordinator()
        self.twoFactorCoordinator = coordinator
        self.deviceConnection = deviceConnection
        self.appSigning = AppleAuthAdapter(twoFactorProvider: coordinator)
        self.appInstalling = appInstalling
        self.pairingFileManaging = pairingFileManaging
        self.refreshCoordinator = RefreshCoordinator(
            appSigning: self.appSigning,
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

    /// Bước 1 của luồng sửa lỗi AFC: chỉ xoá pairing cũ, KHÔNG tự sinh được
    /// file mới (minimuxer không có khả năng đó — xem PairingFileManaging).
    /// Sau bước này, UI phải hỏi người dùng chọn 1 file `.mobiledevicepairing`
    /// rồi gọi `importPairingFile(from:)`.
    func resetPairingFile() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await pairingFileManaging.resetPairingFile()
            vpnStatus = await deviceConnection.currentVPNStatus()
        } catch {
            lastError = FriendlyError(from: error, context: .repairingConnection)
        }
    }

    /// Bước 2: người dùng đã chọn xong file pairing (tạo bằng make_pair_file.py
    /// trên Termux/PC, hoặc lấy từ pairing record của iTunes/Finder).
    func importPairingFile(from url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await pairingFileManaging.importPairingFile(from: url)
            vpnStatus = await deviceConnection.currentVPNStatus()
            lastError = nil
        } catch {
            lastError = FriendlyError(from: error, context: .repairingConnection)
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var twoFactorCoordinator: TwoFactorPromptCoordinator

    var body: some View {
        TabView {
            MyAppsView()
                .tabItem { Label("Ứng dụng", systemImage: "square.grid.2x2") }

            InstallView()
                .tabItem { Label("Cài đặt mới", systemImage: "plus.app") }

            SettingsView()
                .tabItem { Label("Cài đặt hệ thống", systemImage: "gearshape") }
        }
        .sheet(item: $twoFactorCoordinator.pendingRequest) { request in
            TwoFactorCodeSheet(request: request, coordinator: twoFactorCoordinator)
        }
    }
}

/// Sheet hỏi mã 2FA — hiện bất kể lúc đó người dùng đang thao tác ở tab nào,
/// vì AppleGSAClient có thể cần mã này bất cứ lúc nào trong luồng đăng nhập.
private struct TwoFactorCodeSheet: View {
    let request: TwoFactorPromptCoordinator.PendingRequest
    let coordinator: TwoFactorPromptCoordinator
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(methodDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Mã 6 số", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                }
            }
            .navigationTitle("Xác minh 2 bước")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") {
                        coordinator.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xác nhận") {
                        coordinator.submit(code: code)
                        dismiss()
                    }
                    .disabled(code.count < 4)
                }
            }
        }
    }

    private var methodDescription: String {
        switch request.method {
        case "sms": return "Nhập mã vừa gửi qua SMS."
        default: return "Nhập mã hiện trên 1 thiết bị Apple khác đã đăng nhập cùng Apple ID."
        }
    }
}
