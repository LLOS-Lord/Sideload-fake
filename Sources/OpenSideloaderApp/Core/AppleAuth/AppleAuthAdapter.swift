import Foundation

/// Triển khai thật của `AppSigning`, nối AppleGSAClient (xác thực) +
/// DeveloperServicesAPI (App ID / certificate / provisioning profile) thành
/// một luồng hoàn chỉnh — port từ main.py (hàm điều phối chính), không copy
/// code, viết lại bằng Swift async/await.
final class AppleAuthAdapter: AppSigning {

    private let anisette = AnisetteClient()
    private var gsaClient: AppleGSAClient?
    private var authResult: AppleGSAAuthResult?
    private var developerAPI: DeveloperServicesAPI?
    private let twoFactorProvider: TwoFactorCodeProviding
    private let ipaSigning: IpaCodeSigning

    /// Tên certificate dùng để nhận diện "cert do app này tạo" khi cần revoke
    /// bớt trước khi tạo mới (free account giới hạn 2 certificate Development
    /// cùng lúc) — KHÔNG bao giờ revoke certificate không có tiền tố này, để
    /// tránh vô tình thu hồi certificate của Xcode trên máy người dùng.
    private let machineNamePrefix = "opensideloader-"

    init(
        twoFactorProvider: TwoFactorCodeProviding = SwiftUITwoFactorPrompt(),
        ipaSigning: IpaCodeSigning = UnimplementedIpaCodeSigning()
    ) {
        self.twoFactorProvider = twoFactorProvider
        self.ipaSigning = ipaSigning
    }

    func signIn(email: String, password: String) async throws {
        let client = AppleGSAClient(anisette: anisette, twoFactorProvider: twoFactorProvider)
        let result = try await client.authenticate(appleID: email, password: password)
        self.gsaClient = client
        self.authResult = result
        self.developerAPI = DeveloperServicesAPI(auth: result, anisette: anisette)

        // Free Apple ID thường chỉ có 1 team cá nhân — chọn team đầu tiên.
        // Tài khoản Developer Program thật (nhiều team) nên cho người dùng
        // chọn thay vì tự động lấy teams.first — xem README mục 6 (còn cần làm).
        guard let developerAPI else { return }
        let teams = try await developerAPI.listTeams()
        guard let teamId = teams.first?["teamId"] as? String else {
            throw AppSigningError.noTeamFound
        }
        await developerAPI.setTeam(teamId)
    }

    func resign(app: SideloadedApp) async throws -> SideloadedApp {
        guard let developerAPI else { throw AppSigningError.notSignedIn }

        // 1) Đảm bảo có App ID cho bundle identifier này.
        let existingAppIds = try await developerAPI.listAppIds()
        let appIdEntry: [String: Any]
        if let found = existingAppIds.first(where: { ($0["identifier"] as? String) == app.id }) {
            appIdEntry = found
        } else {
            appIdEntry = try await developerAPI.createAppId(bundleId: app.id, name: app.name)
        }
        guard let appIdId = appIdEntry["appIdId"] as? String else {
            throw AppSigningError.missingAppIdId
        }

        // 2) Free account giới hạn 2 certificate iOS Development cùng lúc —
        //    revoke bớt cert CŨ DO CHÍNH APP NÀY TẠO (nhận diện qua tiền tố
        //    tên máy) trước khi tạo cert mới, KHÔNG đụng cert của Xcode.
        let existingCerts = try await developerAPI.listCertificates()
        for cert in existingCerts {
            let name = (cert["attributes"] as? [String: Any])?["name"] as? String ?? ""
            guard name.hasPrefix(machineNamePrefix) else { continue }
            if let certId = cert["id"] as? String {
                _ = try? await developerAPI.revokeCertificate(id: certId)
                try? await Task.sleep(nanoseconds: 3_000_000_000) // chờ Apple xử lý revoke
            }
        }

        // 3) Tạo certificate + private key mới.
        let newCert = try await developerAPI.createCertificate(machineName: "\(machineNamePrefix)\(UUID().uuidString.prefix(8))")
        guard let certificateContent = newCert.certificateContentBase64 else {
            throw AppSigningError.certificateContentNotReady
        }

        // 4) Tải provisioning profile mới cho App ID vừa xác nhận/tạo.
        let profile = try await developerAPI.downloadProvisioningProfile(appIdId: appIdId)
        guard let profileData = profile["encodedProfile"] as? String else {
            throw AppSigningError.missingProvisioningProfile
        }

        // 5) Ký lại — RANH GIỚI CÒN LẠI, xem IpaCodeSigning bên dưới.
        let signedURL = try await ipaSigning.sign(
            appBundlePath: app.id, // TODO: đường dẫn .app thật đã giải nén, không phải bundle id
            certificatePEM: newCert.privateKeyPEM,
            certificateContentBase64: certificateContent,
            provisioningProfileBase64: profileData
        )
        _ = signedURL

        return SideloadedApp(
            id: app.id,
            name: app.name,
            version: app.version,
            iconSystemName: app.iconSystemName,
            installedDate: app.installedDate,
            expirationDate: Date().addingTimeInterval(7 * 24 * 60 * 60)
        )
    }
}

enum AppSigningError: LocalizedError {
    case notSignedIn
    case noTeamFound
    case missingAppIdId
    case certificateContentNotReady
    case missingProvisioningProfile

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Chưa đăng nhập Apple ID."
        case .noTeamFound: return "Không tìm thấy team Apple Developer nào cho tài khoản này."
        case .missingAppIdId: return "Không lấy được appIdId sau khi tạo/tra App ID."
        case .certificateContentNotReady: return "Apple chưa đồng bộ xong nội dung certificate — thử lại sau vài giây."
        case .missingProvisioningProfile: return "Không tải được provisioning profile."
        }
    }
}

/// RANH GIỚI CÒN LẠI CỦA TOÀN BỘ PROJECT: ký thật vào file .app bằng
/// certificate + provisioning profile (tương đương lệnh `zsign -f -t <tmp> -c
/// cert.pem -k key.pem -m profile.mobileprovision -o out.ipa app/` trong bản
/// tham chiếu Python). zsign là binary MIT license nhưng KHÔNG exec được
/// trong sandbox app iOS (không có subprocess/fork+exec) — cần 1 trong 2:
///   (a) build lại core signing logic của zsign (C++, MIT) thành static
///       library rồi gọi qua bridging header, KHÔNG dùng subprocess
///   (b) viết signer CMS thuần Swift dùng Security framework
///       (SecCMSEncoderCreate...) — tương đương phần lõi AltSign làm, nhưng
///       tự viết lại chứ không copy AltSign
/// Cả 2 đều là công việc riêng, chưa nằm trong phạm vi đã port ở đây.
protocol IpaCodeSigning {
    func sign(
        appBundlePath: String,
        certificatePEM: String,
        certificateContentBase64: String,
        provisioningProfileBase64: String
    ) async throws -> URL
}

struct UnimplementedIpaCodeSigning: IpaCodeSigning {
    func sign(appBundlePath: String, certificatePEM: String, certificateContentBase64: String, provisioningProfileBase64: String) async throws -> URL {
        throw AppSigningError.missingProvisioningProfile // placeholder — xem comment ở IpaCodeSigning
    }
}

/// UI (SignInSheet) implement bằng cách hiện ô nhập mã, KHÔNG chặn thread
/// chính trong lúc chờ người dùng gõ mã.
struct SwiftUITwoFactorPrompt: TwoFactorCodeProviding {
    func requestCode(method: String) async -> String? {
        nil // TODO: nối với 1 sheet SwiftUI thật, xem SettingsView.swift
    }
}
