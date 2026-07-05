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

/// Gộp toàn bộ quy trình sửa lỗi AFC/pairing đã biết là hiệu quả thành MỘT màn hình,
/// thay vì rải rác nhiều bước thủ công như tài liệu troubleshooting gốc.
private struct PairingTroubleshootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var isRepairing = false
    @State private var didFinish = false

    var body: some View {
        List {
            Section {
                Text("Lỗi \"AFC was unable to manage files\" gần như luôn do hồ sơ ghép nối (pairing) giữa app và thiết bị bị hỏng hoặc cũ — không phải lỗi của app bạn đang cài.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Quy trình sửa tự động") {
                Label("Xoá hồ sơ ghép nối cũ", systemImage: "1.circle")
                Label("Tạo hồ sơ ghép nối mới trực tiếp trên thiết bị này", systemImage: "2.circle")
                Label("Kiểm tra lại Wi-Fi + VPN cục bộ", systemImage: "3.circle")
            }

            Section {
                Button {
                    Task { await repair() }
                } label: {
                    if isRepairing {
                        HStack { ProgressView(); Text("Đang sửa...") }
                    } else {
                        Text("Sửa ngay")
                    }
                }
                .disabled(isRepairing)

                if didFinish {
                    Label("Đã hoàn tất — thử cài hoặc làm mới app lại xem sao.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Nếu vẫn không được") {
                Text("• Đảm bảo Wi-Fi đang bật, không dùng data di động\n• Đổi máy chủ anisette trong Cài đặt nâng cao\n• Khởi động lại thiết bị")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sửa lỗi kết nối")
    }

    private func repair() async {
        isRepairing = true
        defer { isRepairing = false }
        await environment.repairPairingAndVPN()
        didFinish = environment.lastError == nil
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
