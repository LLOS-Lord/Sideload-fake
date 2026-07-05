import Foundation
import Crypto
import _CryptoExtras
import X509
import SwiftASN1

/// Client cho Apple Developer Services (developerservices2.apple.com), port từ
/// một tool Python tương đương (đối chiếu logic, không copy code — Python
/// không compile được thành Swift nên đây bắt buộc là bản viết lại).
///
/// Endpoint, tên field, và 3 "FIX" dưới đây được giữ nguyên ý nghĩa từ bản
/// tham chiếu vì chúng phản ánh hành vi THẬT của server Apple (đã được người
/// viết bản gốc xác minh qua thực nghiệm, không phải suy đoán):
///   FIX-1  revoke certificate qua DELETE services/v1/certificates/{id}
///   FIX-2  cache anisette 60s (không phải 300s) — tránh resultCode 1100
///   FIX-3  gặp resultCode 1100 (session expired) → làm mới anisette, thử lại 1 lần
///   FIX-Akamai  endpoint services/v1/* có lớp edge chặn thẳng verb DELETE/PUT
///               thật (trả 403 HTML thô, không phải lỗi JSON) → phải giả bằng
///               POST + header X-HTTP-Method-Override
actor DeveloperServicesAPI {
    private let auth: AppleGSAAuthResult
    private let anisette: AnisetteClient
    private let session: URLSession

    private let baseURL = "https://developerservices2.apple.com/services/QH65B2"
    private let servicesBaseURL = "https://developerservices2.apple.com/services/v1"
    private let clientId = "XABBG36SBA"
    private let protocolVersion = "QH65B2"
    private let xcodeVersion = "11.2 (11B41)"

    private(set) var teamId: String?

    private var cachedAnisette: [String: String]?
    private var lastAnisetteTime: Date = .distantPast

    init(auth: AppleGSAAuthResult, anisette: AnisetteClient, session: URLSession = .shared) {
        self.auth = auth
        self.anisette = anisette
        self.session = session
    }

    func setTeam(_ id: String) {
        teamId = id
    }

    // MARK: - Helpers

    /// FIX-2: cache 60s thay vì 300s.
    private func currentAnisette(force: Bool = false) async -> [String: String] {
        if force || cachedAnisette == nil || Date().timeIntervalSince(lastAnisetteTime) > 60 {
            cachedAnisette = try? await anisette.fetchHeaders()
            lastAnisetteTime = Date()
        }
        return cachedAnisette ?? [:]
    }

    private func authHeaders(contentType: String, accept: String) async -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": contentType,
            "User-Agent": "Xcode",
            "Accept": accept,
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": xcodeVersion,
            "X-Apple-I-Identity-Id": auth.dsid,
            "X-Apple-GS-Token": auth.sessionToken,
        ]
        for (k, v) in await currentAnisette() { headers[k] = v }
        return headers
    }

    struct DeveloperAPIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Gọi 1 action-plist trên developerservices2. FIX-3: resultCode 1100 →
    /// retry đúng 1 lần với anisette mới trước khi báo lỗi.
    private func makeDeveloperRequest(
        _ actionPath: String,
        extraParams: [String: Any] = [:],
        requireTeam: Bool = true
    ) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let headers = await authHeaders(contentType: "text/x-xml-plist", accept: "text/x-xml-plist")

            var params: [String: Any] = [
                "clientId": clientId,
                "protocolVersion": protocolVersion,
                "requestId": UUID().uuidString.uppercased(),
            ]
            if requireTeam {
                guard let teamId else {
                    throw DeveloperAPIError(message: "Chưa có teamId — gọi listTeams()/setTeam() trước.")
                }
                params["teamId"] = teamId
            }
            for (k, v) in extraParams { params[k] = v }

            guard let url = URL(string: "\(baseURL)/\(actionPath)?clientId=\(clientId)") else {
                throw DeveloperAPIError(message: "URL không hợp lệ: \(actionPath)")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: params, format: .xml, options: 0)
            request.timeoutInterval = 30

            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw DeveloperAPIError(message: "HTTP \(http.statusCode) trên \(actionPath)")
                }
                guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw DeveloperAPIError(message: "Response không phải plist hợp lệ trên \(actionPath)")
                }

                let resultCode = (plist["resultCode"] as? Int) ?? (plist["resultcode"] as? Int)
                if resultCode == 1100, attempt == 0 {
                    _ = await currentAnisette(force: true)
                    continue
                }
                return plist
            } catch {
                if attempt == 0 {
                    _ = await currentAnisette(force: true)
                    continue
                }
                throw error
            }
        }
        throw DeveloperAPIError(message: "Request '\(actionPath)' thất bại sau 2 lần thử.")
    }

    // MARK: - Teams

    func listTeams() async throws -> [[String: Any]] {
        let response = try await makeDeveloperRequest("listTeams.action", requireTeam: false)
        return (response["teams"] as? [[String: Any]]) ?? []
    }

    // MARK: - Devices

    func listDevices() async throws -> [[String: Any]] {
        let response = try await makeDeveloperRequest("ios/listDevices.action")
        return (response["devices"] as? [[String: Any]]) ?? []
    }

    func registerDevice(name: String, udid: String) async throws -> [String: Any] {
        let response = try await makeDeveloperRequest("ios/addDevice.action", extraParams: [
            "deviceNumber": udid,
            "name": name,
        ])
        guard let device = response["device"] as? [String: Any] else {
            throw DeveloperAPIError(message: "Đăng ký thiết bị thất bại: \(response)")
        }
        return device
    }

    // MARK: - App IDs

    func listAppIds() async throws -> [[String: Any]] {
        let response = try await makeDeveloperRequest("ios/listAppIds.action")
        return (response["appIds"] as? [[String: Any]]) ?? []
    }

    func createAppId(bundleId: String, name: String) async throws -> [String: Any] {
        let sanitizedName = name.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
        let response = try await makeDeveloperRequest("ios/addAppId.action", extraParams: [
            "identifier": bundleId,
            "name": sanitizedName.isEmpty ? "App" : sanitizedName,
        ])
        guard let appId = response["appId"] as? [String: Any] else {
            throw DeveloperAPIError(message: "Tạo App ID thất bại: \(response)")
        }
        return appId
    }

    // MARK: - Certificates (JSON v1 API)

    /// FIX-Akamai: giả GET bằng POST + X-HTTP-Method-Override, vì gọi GET/DELETE
    /// thật trên cụm services/v1 có thể bị lớp edge chặn (403 HTML thô, không
    /// phải JSON) tuỳ theo endpoint và thời điểm.
    func listCertificates() async throws -> [[String: Any]] {
        guard let teamId else { throw DeveloperAPIError(message: "Chưa có teamId.") }
        guard let url = URL(string: "\(servicesBaseURL)/certificates") else {
            throw DeveloperAPIError(message: "URL certificates không hợp lệ.")
        }
        let query = "teamId=\(teamId)&filter[certificateType]=IOS_DEVELOPMENT"
        _ = await currentAnisette(force: true)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in await authHeaders(contentType: "application/vnd.api+json", accept: "application/vnd.api+json") {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("GET", forHTTPHeaderField: "X-HTTP-Method-Override")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["urlEncodedQueryParams": query])
        request.timeoutInterval = 30

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeveloperAPIError(message: "Response certificates không phải JSON hợp lệ.")
        }
        return (json["data"] as? [[String: Any]]) ?? []
    }

    /// FIX-1 + FIX-Akamai: revoke qua DELETE giả lập bằng POST.
    /// CHỈ revoke certificate do chính app này tạo — không đụng cert của Xcode.
    @discardableResult
    func revokeCertificate(id: String) async throws -> Bool {
        guard let teamId else { throw DeveloperAPIError(message: "Chưa có teamId.") }
        guard let url = URL(string: "\(servicesBaseURL)/certificates/\(id)") else {
            throw DeveloperAPIError(message: "URL revoke không hợp lệ.")
        }
        let query = "teamId=\(teamId)"
        _ = await currentAnisette(force: true)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in await authHeaders(contentType: "application/vnd.api+json", accept: "application/vnd.api+json") {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("DELETE", forHTTPHeaderField: "X-HTTP-Method-Override")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["urlEncodedQueryParams": query])
        request.timeoutInterval = 30

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 || http.statusCode == 204
    }

    /// Poll v1 API lấy `certificateContent` cho cert vừa nộp CSR — Apple cần
    /// vài giây để đồng bộ, retry với backoff 3/5/8s giống bản tham chiếu.
    private func fetchCertificateContent(id: String) async -> String? {
        let delays: [UInt64] = [3, 5, 8]
        for delay in delays {
            if let certs = try? await listCertificates() {
                for cert in certs {
                    let certId = (cert["id"] as? String) ?? ((cert["attributes"] as? [String: Any])?["certificateId"] as? String)
                    if certId == id {
                        if let content = (cert["attributes"] as? [String: Any])?["certificateContent"] as? String {
                            return content
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
        return nil
    }

    struct NewCertificate {
        let certificateId: String
        /// PEM PKCS#1/PKCS#8 — dùng để ký ipa ở bước sau (xem README mục "còn cần làm").
        let privateKeyPEM: String
        /// Base64 DER certificate content (nếu Apple đã đồng bộ xong).
        let certificateContentBase64: String?
    }

    /// Sinh RSA 2048-bit + CSR bằng `swift-certificates` (Apache 2.0, KHÔNG phải
    /// AGPL), nộp lên Apple, rồi poll certificateContent.
    ///
    /// ⚠️ MỨC ĐỘ TIN CẬY: shape của `CertificateSigningRequest(version:subject:
    /// privateKey:attributes:signatureAlgorithm:)` và `serializeAsPEM(discriminator:)`
    /// đã xác nhận qua ví dụ thật (Apple Developer Forums + tài liệu chính thức),
    /// nhưng ví dụ đó dùng khoá P256 — với khoá RSA (`_RSA.Signing.PrivateKey`,
    /// module `_CryptoExtras`), tên case chữ ký `.sha256WithRSAEncryption` CHƯA
    /// được xác nhận trực tiếp, hãy để Xcode tự động gợi ý case đúng nếu tên này
    /// sai (autocomplete trên `Certificate.SignatureAlgorithm`).
    func createCertificate(machineName: String = "opensideloader") async throws -> NewCertificate {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let certPrivateKey = Certificate.PrivateKey(privateKey)

        let subject = try DistinguishedName([
            .init(type: .NameAttributes.commonName, utf8String: machineName)
        ])
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: subject,
            privateKey: certPrivateKey,
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha256WithRSAEncryption
        )
        let csrPEM = try csr.serializeAsPEM(discriminator: CertificateSigningRequest.defaultPEMDiscriminator).pemString
        let machineId = UUID().uuidString.uppercased()

        let response = try await makeDeveloperRequest("ios/submitDevelopmentCSR.action", extraParams: [
            "csrContent": csrPEM,
            "machineId": machineId,
            "machineName": machineName,
        ])
        guard let certRequest = response["certRequest"] as? [String: Any],
              let certificateId = certRequest["certificateId"] as? String else {
            throw DeveloperAPIError(message: "Không tạo được certificate: \(response)")
        }

        // PEM PKCS#1 của private key — cần cho bước ký ipa sau này.
        let privateKeyPEM = privateKey.pemRepresentation

        let content = await fetchCertificateContent(id: certificateId)
        return NewCertificate(certificateId: certificateId, privateKeyPEM: privateKeyPEM, certificateContentBase64: content)
    }

    // MARK: - Provisioning Profile

    func listProvisioningProfiles() async throws -> [[String: Any]] {
        let response = try await makeDeveloperRequest("ios/listProvisioningProfiles.action")
        return (response["provisioningProfiles"] as? [[String: Any]]) ?? []
    }

    /// Sau khi tạo cert mới, Apple cần vài giây để tích hợp vào Team Profile —
    /// retry với delay tăng dần (3, 5, 7...) giống bản tham chiếu.
    func downloadProvisioningProfile(appIdId: String, retries: Int = 3) async throws -> [String: Any] {
        var delay: UInt64 = 3
        var lastError: Error?
        for attempt in 0..<retries {
            do {
                let response = try await makeDeveloperRequest("ios/downloadTeamProvisioningProfile.action", extraParams: [
                    "appIdId": appIdId,
                ])
                if let profile = response["provisioningProfile"] as? [String: Any] {
                    return profile
                }
            } catch {
                lastError = error
            }
            if attempt < retries - 1 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay += 2
            }
        }
        throw lastError ?? DeveloperAPIError(message: "Không tải được provisioning profile sau \(retries) lần thử.")
    }
}
