import SwiftUI
import UniformTypeIdentifiers

struct InstallView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var isPickingFile = false
    @State private var sourceURLText = ""
    @State private var isInstalling = false
    @State private var installProgressLabel: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Từ file trên máy") {
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Chọn file .ipa", systemImage: "doc.badge.plus")
                    }
                }

                Section("Từ liên kết nguồn (source URL)") {
                    TextField("https://vidu.com/app.ipa", text: $sourceURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        Task { await installFromURLText() }
                    } label: {
                        if isInstalling {
                            HStack {
                                ProgressView()
                                Text(installProgressLabel ?? "Đang cài...")
                            }
                        } else {
                            Text("Cài đặt")
                        }
                    }
                    .disabled(sourceURLText.isEmpty || isInstalling || !environment.vpnStatus.isHealthy)
                }

                if !environment.vpnStatus.isHealthy {
                    Section {
                        Label(
                            "Cần Wi-Fi + VPN cục bộ đang kết nối trước khi cài được app.",
                            systemImage: "wifi.exclamationmark"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Cài đặt mới")
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleFilePicked(result) }
            }
        }
    }

    private func installFromURLText() async {
        guard let url = URL(string: sourceURLText) else { return }
        await install(from: url)
    }

    private func handleFilePicked(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, let url = urls.first else { return }
        await install(from: url)
    }

    private func install(from url: URL) async {
        isInstalling = true
        installProgressLabel = "Đang tải và ký lại..."
        defer {
            isInstalling = false
            installProgressLabel = nil
        }

        do {
            let installed = try await environment.appInstalling.install(ipaURL: url)
            environment.installedApps.append(installed)
            sourceURLText = ""
        } catch {
            environment.lastError = FriendlyError(
                from: error,
                context: .installingApp(url.lastPathComponent)
            )
        }
    }
}
