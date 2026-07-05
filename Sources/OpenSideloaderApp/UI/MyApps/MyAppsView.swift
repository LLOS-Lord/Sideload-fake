import SwiftUI

struct MyAppsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var refreshingAppIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if !environment.vpnStatus.isHealthy {
                    VPNWarningBanner()
                }

                if environment.installedApps.isEmpty {
                    ContentUnavailableViewCompat()
                } else {
                    ForEach(environment.installedApps) { app in
                        AppRow(
                            app: app,
                            isRefreshing: refreshingAppIDs.contains(app.id),
                            onRefresh: { await refresh(app) }
                        )
                    }
                }
            }
            .navigationTitle("Ứng dụng")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("Làm mới tất cả", systemImage: "arrow.clockwise")
                    }
                    .disabled(environment.isBusy || environment.installedApps.isEmpty)
                }
            }
            .refreshable { await refreshAll() }
            .alert(item: $environment.lastError) { error in
                Alert(
                    title: Text(error.title),
                    message: Text(error.message),
                    primaryButton: .default(Text("Sửa ngay")) {
                        Task { await environment.repairPairingAndVPN() }
                    },
                    secondaryButton: .cancel(Text("Để sau"))
                )
            }
        }
    }

    private func refresh(_ app: SideloadedApp) async {
        refreshingAppIDs.insert(app.id)
        defer { refreshingAppIDs.remove(app.id) }
        do {
            let updated = try await environment.refreshCoordinator.refreshNow(app)
            environment.handle(.success(updated))
        } catch {
            environment.handle(.failure(app, error))
        }
    }

    private func refreshAll() async {
        for app in environment.installedApps {
            await refresh(app)
        }
    }
}

private struct AppRow: View {
    let app: SideloadedApp
    let isRefreshing: Bool
    let onRefresh: () async -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: app.iconSystemName)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline)
                Text(expiryText)
                    .font(.subheadline)
                    .foregroundStyle(app.isExpiringSoon ? .red : .secondary)
            }

            Spacer()

            if isRefreshing {
                ProgressView()
            } else {
                Button {
                    Task { await onRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var expiryText: String {
        app.daysRemaining <= 0
            ? "Hết hạn hôm nay — cần làm mới ngay"
            : "Còn \(app.daysRemaining) ngày trước khi hết hạn"
    }
}

private struct VPNWarningBanner: View {
    var body: some View {
        Label {
            Text("Chưa kết nối Wi-Fi + VPN cục bộ (StosVPN). Không thể cài hoặc làm mới app cho tới khi kết nối xong.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .listRowBackground(Color.orange.opacity(0.1))
    }
}

/// Vài Xcode/iOS cũ chưa có `ContentUnavailableView` — bản tương thích ngược đơn giản.
private struct ContentUnavailableViewCompat: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Chưa có app nào được cài")
                .font(.headline)
            Text("Bấm tab \"Cài đặt mới\" để bắt đầu.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
