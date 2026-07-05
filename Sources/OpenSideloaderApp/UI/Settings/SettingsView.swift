import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showingSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Tài khoản Apple") {
                    if let email = environment.appleAccountEmail {
                        LabeledContent("Đã đăng nhập", value: email)
                    } else {
                        Button("Đăng nhập Apple ID") { showingSignIn = true }
                    }
                }

                Section("Kết nối thiết bị") {
                    LabeledContent("Trạng thái VPN cục bộ", value: vpnStatusText)
                    NavigationLink("Sửa lỗi kết nối / lỗi AFC") {
                        PairingTroubleshootView()
                    }
                }

                Section("Nâng cao") {
                    NavigationLink("Máy chủ anisette") {
                        Text("Danh sách máy chủ anisette — điền URL máy chủ bạn muốn dùng nếu máy chủ mặc định không phản hồi.")
                            .padding()
                    }
                }
            }
            .navigationTitle("Cài đặt hệ thống")
            .sheet(isPresented: $showingSignIn) {
                SignInSheet()
            }
        }
    }

    private var vpnStatusText: String {
        switch environment.vpnStatus {
        case .unknown: return "Chưa rõ"
        case .disconnected: return "Chưa kết nối"
        case .connectedWrongNetwork: return "Đang dùng data di động (cần Wi-Fi)"
        case .connected(let ip): return "Đã kết nối (\(ip))"
        }
    }
}

/// Gộp quy trình sửa lỗi AFC/pairing thành 1 màn hình — nhưng KHÔNG giả vờ tự
/// sinh được pairing file mới (minimuxer không có khả năng đó, xem
/// CoreProtocols.swift). Bước 2 bắt buộc người dùng tự chọn 1 file đã tạo từ
/// bên ngoài (Termux/PC qua make_pair_file.py, hoặc rút từ iTunes/Finder).
private struct PairingTroubleshootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var isWorking = false
    @State private var isPickingFile = false
    @State private var hasPairingFile = false

    var body: some View {
        List {
            Section {
                Text("Lỗi \"AFC was unable to manage files\" gần như luôn do hồ sơ ghép nối (pairing) giữa app và thiết bị bị hỏng hoặc cũ — không phải lỗi của app bạn đang cài.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Trạng thái hiện tại") {
                Label(
                    hasPairingFile ? "Đã có pairing file hợp lệ" : "Chưa có pairing file",
                    systemImage: hasPairingFile ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(hasPairingFile ? .green : .secondary)
            }

            Section("Bước 1 — Xoá pairing cũ (nếu có)") {
                Button {
                    Task { await resetOnly() }
                } label: {
                    if isWorking {
                        HStack { ProgressView(); Text("Đang xoá...") }
                    } else {
                        Text("Xoá pairing cũ")
                    }
                }
                .disabled(isWorking)
            }

            Section("Bước 2 — Nhập pairing file mới") {
                Text("minimuxer KHÔNG tự tạo được pairing file mới trên chính máy — cần tạo từ bên ngoài rồi nhập vào đây:\n\n• Chạy make_pair_file.py trên Termux/PC (máy phải đặt mã khoá màn hình và đang mở khoá lúc chạy)\n• AirDrop hoặc copy file .mobiledevicepairing vào Files app trên chính điện thoại này\n• Bấm nút dưới, chọn đúng file đó")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Chọn file pairing...") {
                    isPickingFile = true
                }
                .disabled(isWorking)
            }

            Section("Nếu vẫn không được") {
                Text("• Đảm bảo Wi-Fi đang bật, không dùng data di động\n• Kiểm tra StosVPN đang connected\n• Máy phải đặt mã khoá màn hình và mở khoá lúc tạo pairing file\n• Thiết bị iOS ≤ 17.3 mới dùng được cách này (17.4+ đổi sang RemotePairing)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sửa lỗi kết nối")
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.data]) { result in
            Task { await handlePicked(result) }
        }
        .task { hasPairingFile = await environment.pairingFileManaging.hasValidPairingFile() }
    }

    private func resetOnly() async {
        isWorking = true
        defer { isWorking = false }
        await environment.resetPairingFile()
        hasPairingFile = await environment.pairingFileManaging.hasValidPairingFile()
    }

    private func handlePicked(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        isWorking = true
        defer { isWorking = false }
        await environment.importPairingFile(from: url)
        hasPairingFile = await environment.pairingFileManaging.hasValidPairingFile()
    }
}

private struct SignInSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Apple ID", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("Mật khẩu", text: $password)
            }
            .navigationTitle("Đăng nhập")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSigningIn ? "Đang vào..." : "Xong") {
                        Task { await signIn() }
                    }
                    .disabled(email.isEmpty || password.isEmpty || isSigningIn)
                }
            }
        }
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await environment.appSigning.signIn(email: email, password: password)
            environment.appleAccountEmail = email
            dismiss()
        } catch {
            environment.lastError = FriendlyError(from: error, context: .signingIn)
        }
    }
}
