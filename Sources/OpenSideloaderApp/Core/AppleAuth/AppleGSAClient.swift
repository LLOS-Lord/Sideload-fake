import Foundation
import BigInt
import Crypto
import CCommonCryptoShim

/// Kết quả xác thực GSA thành công.
struct AppleGSAAuthResult {
    let appleID: String
    let dsid: String
    /// Token đã đổi qua fetchAppToken cho đúng app cụ thể (vd
    /// "com.apple.gs.xcode.auth" cho Developer Services API). Nếu đổi thất
    /// bại, rơi về GsIdmsToken thô — vẫn dùng tạm được với một số endpoint.
    let sessionToken: String
    /// Cần giữ lại để tự đổi thêm app-token khác sau này nếu cần
    /// (vd nếu Developer Services API đổi yêu cầu audience khác).
    let spd: [String: Any]
}

enum AppleGSAError: LocalizedError {
    case unsupportedProtocol(String)
    case missingField(String)
    case srpChallengeFailed
    case serverProofMismatch
    case twoFactorRequiredButNoCodeProvided
    case twoFactorFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol(let p): return "Apple yêu cầu giao thức SRP không được hỗ trợ: \(p)"
        case .missingField(let f): return "Thiếu trường bắt buộc trong phản hồi của Apple: \(f)"
        case .srpChallengeFailed: return "Không xử lý được thử thách SRP (tham số từ Apple không hợp lệ)."
        case .serverProofMismatch: return "Xác thực bị từ chối: M2 từ Apple không khớp phiên SRP cục bộ (sai mật khẩu, hoặc lỗi anisette)."
        case .twoFactorRequiredButNoCodeProvided: return "Tài khoản cần xác thực 2 yếu tố nhưng chưa có mã được cung cấp."
        case .twoFactorFailed: return "Xác thực 2 yếu tố thất bại."
        case .invalidResponse: return "Phản hồi không hợp lệ từ máy chủ Apple."
        }
    }
}

/// Cách lấy mã 2FA từ người dùng — UI (SettingsView/SignInSheet) implement
/// protocol này bằng cách hiện 1 ô nhập mã 6 số, tương đương input() phía
/// Python nhưng không chặn thread.
protocol TwoFactorCodeProviding {
    /// method: "trustedDevice" hoặc "sms" — để UI hiển thị đúng thông điệp.
    func requestCode(method: String) async -> String?
}

actor AppleGSAClient {
    private let identity = AppleClientIdentity()
    private let anisette: AnisetteClient
    private let session: URLSession
    private let twoFactorProvider: TwoFactorCodeProviding

    private let userAgent = "akd/1.0 CFNetwork/1408.0.4 Darwin/22.5.0"
    private let xcodeUserAgent = "com.apple.dt.Xcode/14.2 (14C18) akd/1.0 CFNetwork/1408.0.4 Darwin/22.5.0"

    init(anisette: AnisetteClient, twoFactorProvider: TwoFactorCodeProviding, session: URLSession = .shared) {
        self.anisette = anisette
        self.twoFactorProvider = twoFactorProvider
        self.session = session
    }

    // MARK: - CPD / anisette gộp

    private func generateCPD() async throws -> [String: Any] {
        let anisetteHeaders = try await anisette.fetchHeaders()
        var cpd: [String: Any] = [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
        ]
        for (k, v) in identity.metaHeaders() { cpd[k] = v }
        for (k, v) in anisetteHeaders { cpd[k] = v }
        return cpd
    }

    // MARK: - Plist HTTP tới GSA

    private func gsaRequest(_ parameters: [String: Any]) async throws -> [String: Any] {
        let cpd = try await generateCPD()
        let body: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": parameters.merging(["cpd": cpd]) { a, _ in a },
        ]

        var request = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
        request.httpMethod = "POST"
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(identity.clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw AppleGSAError.invalidResponse
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let result = plist["Response"] as? [String: Any] else {
            throw AppleGSAError.invalidResponse
        }
        return result
    }

    // MARK: - Mã hoá mật khẩu theo protocol Apple (s2k / s2k_fo)

    private func encryptPassword(_ password: String, salt: Data, iterations: Int, protocolName: String) -> Data {
        var p = Data(SHA256.hash(data: Data(password.utf8)))
        if protocolName == "s2k_fo" {
            p = Data(p.map { String(format: "%02x", $0) }.joined().utf8)
        }
        return PBKDF2.sha256(password: p, salt: salt, iterations: iterations, keyLength: 32)
    }

    // MARK: - Giải mã AES-CBC cho trường "spd" (dùng CommonCrypto, xem shim)

    private func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private func decryptCBC(sessionKey K: Data, data: Data) throws -> Data {
        let extraDataKey = hmacSHA256(key: K, message: Data("extra data key:".utf8))
        let extraDataIV = hmacSHA256(key: K, message: Data("extra data iv:".utf8)).prefix(16)

        var outLength = data.count + kCCBlockSizeAES128
        var outData = Data(count: outLength)
        var moved = 0

        let status = outData.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            data.withUnsafeBytes { inPtr -> CCCryptorStatus in
                extraDataKey.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                    extraDataIV.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, extraDataKey.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outLength,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw AppleGSAError.invalidResponse
        }
        return outData.prefix(moved)
    }

    /// Giải mã trường "et" (encrypted token) từ bước apptokens — AES-GCM, cấu
    /// trúc [3 byte 'XYZ' AAD][16 byte IV][ciphertext][16 byte tag], y hệt
    /// decrypt_gcm phía Python.
    private func decryptGCM(sessionKey sk: Data, encryptedData: Data) throws -> Data {
        guard encryptedData.count >= 35, encryptedData.prefix(3) == Data("XYZ".utf8) else {
            throw AppleGSAError.invalidResponse
        }
        let iv = encryptedData.subdata(in: 3..<19)
        let ciphertext = encryptedData.subdata(in: 19..<(encryptedData.count - 16))
        let tag = encryptedData.suffix(16)

        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: sk))
    }

    // MARK: - Đổi GsIdmsToken lấy app token thật (vd cho Developer Services API)

    private func fetchAppToken(adsid: String, c: Data, idmsToken: String, sk: Data, app: String) async throws -> String? {
        var checksumMAC = HMAC<SHA256>(key: SymmetricKey(data: sk))
        checksumMAC.update(data: Data("apptokens".utf8))
        checksumMAC.update(data: Data(adsid.utf8))
        checksumMAC.update(data: Data(app.utf8))
        let checksum = Data(checksumMAC.finalize())

        let response = try await gsaRequest([
            "u": adsid,
            "app": [app],
            "c": c,
            "t": idmsToken,
            "checksum": checksum,
            "o": "apptokens",
        ])

        guard let encryptedToken = response["et"] as? Data else { return nil }
        let decrypted = try decryptGCM(sessionKey: sk, encryptedData: encryptedToken)
        guard let tokenPlist = try PropertyListSerialization.propertyList(from: decrypted, options: [], format: nil) as? [String: Any],
              let tokens = tokenPlist["t"] as? [String: Any],
              let tokenInfo = tokens[app] as? [String: Any],
              let token = tokenInfo["token"] as? String else {
            return nil
        }
        return token
    }

    // MARK: - Luồng chính: SRP + (nếu cần) 2FA

    func authenticate(appleID: String, password: String, depth: Int = 0) async throws -> AppleGSAAuthResult {
        let clientKeys = SRPMath.generateClientKeys()

        let initResponse = try await gsaRequest([
            "A2k": pad(clientKeys.A),
            "ps": ["s2k", "s2k_fo"],
            "u": appleID,
            "o": "init",
        ])

        guard let protocolName = initResponse["sp"] as? String, ["s2k", "s2k_fo"].contains(protocolName) else {
            throw AppleGSAError.unsupportedProtocol((initResponse["sp"] as? String) ?? "?")
        }
        guard let salt = initResponse["s"] as? Data,
              let bData = initResponse["B"] as? Data,
              let c = initResponse["c"] as? Data,
              let iterations = initResponse["i"] as? Int else {
            throw AppleGSAError.missingField("s/B/c/i")
        }

        let B = BigUInt(bData)
        let processedPassword = encryptPassword(password, salt: salt, iterations: iterations, protocolName: protocolName)

        let k = SRPMath.computeK()
        let x = SRPMath.computeX(salt: salt, processedPassword: processedPassword)
        let u = SRPMath.computeU(A: clientKeys.A, B: B)
        guard u != 0, B % SRPMath.N != 0 else { throw AppleGSAError.srpChallengeFailed }

        let sharedSecret = SRPMath.computeSharedSecret(clientKeys: clientKeys, serverPublicKeyB: B, k: k, x: x, u: u)
        let sessionKey = SRPMath.computeSessionKey(sharedSecret: sharedSecret)
        let M1 = SRPMath.computeM1(username: appleID, salt: salt, A: clientKeys.A, B: B, sessionKey: sessionKey)

        let completeResponse = try await gsaRequest([
            "c": c,
            "M1": M1,
            "u": appleID,
            "o": "complete",
        ])

        let status = completeResponse["Status"] as? [String: Any] ?? [:]
        let authType = status["au"] as? String

        var m2Verified = false
        if let m2 = completeResponse["M2"] as? Data {
            let expectedM2 = SRPMath.computeExpectedM2(A: clientKeys.A, M1: M1, sessionKey: sessionKey)
            m2Verified = (m2 == expectedM2)
        }

        var spd: [String: Any] = [:]
        if m2Verified, let spdEncrypted = completeResponse["spd"] as? Data {
            if let decrypted = try? decryptCBC(sessionKey: sessionKey, data: spdEncrypted),
               let parsed = try? PropertyListSerialization.propertyList(from: decrypted, options: [], format: nil) as? [String: Any] {
                spd = parsed
            }
        }

        // ---- Xử lý 2FA ----
        if let authType, ["trustedDeviceSecondaryAuth", "secondaryAuth", "smsSecondaryAuth"].contains(authType) {
            let dsid = (spd["adsid"] as? String) ?? (spd["dsid"] as? String) ?? (status["dsid"] as? String)
            let idmsToken = (spd["GsIdmsToken"] as? String) ?? (spd["idmsToken"] as? String) ?? (status["idmsToken"] as? String)

            guard let dsid, let idmsToken else {
                throw AppleGSAError.missingField("dsid/idmsToken cho luồng 2FA")
            }

            let ok: Bool
            if authType == "smsSecondaryAuth" {
                ok = await handleSMS(dsid: dsid, idmsToken: idmsToken)
            } else {
                ok = await handleTrustedDevice(dsid: dsid, idmsToken: idmsToken)
            }
            guard ok else { throw AppleGSAError.twoFactorFailed }

            if depth >= 1 {
                // Giống bản Python: 2FA xong nhưng phiên đầy đủ cần chạy lại 1 lần.
                throw AppleGSAError.twoFactorRequiredButNoCodeProvided
            }
            return try await authenticate(appleID: appleID, password: password, depth: depth + 1)
        }

        guard m2Verified else { throw AppleGSAError.serverProofMismatch }

        let dsid = (spd["adsid"] as? String) ?? (spd["dsid"] as? String) ?? (completeResponse["dsid"] as? String) ?? (status["dsid"] as? String)
        guard let dsid else { throw AppleGSAError.missingField("dsid") }

        var sessionTokenFinal = (spd["GsIdmsToken"] as? String) ?? (completeResponse["sessionToken"] as? String) ?? (status["idmsToken"] as? String) ?? ""

        if let apptokenAdsid = (spd["adsid"] as? String) ?? Optional(dsid),
           let apptokenC = spd["c"] as? Data,
           let apptokenSK = spd["sk"] as? Data,
           let apptokenIdms = spd["GsIdmsToken"] as? String {
            if let realToken = try? await fetchAppToken(
                adsid: apptokenAdsid, c: apptokenC, idmsToken: apptokenIdms, sk: apptokenSK,
                app: "com.apple.gs.xcode.auth"
            ) {
                sessionTokenFinal = realToken
            }
        }

        return AppleGSAAuthResult(appleID: appleID, dsid: dsid, sessionToken: sessionTokenFinal, spd: spd)
    }

    private func pad(_ value: BigUInt) -> Data { value.serialize() }

    // MARK: - 2FA: trusted device

    private func build2FAHeaders(dsid: String, idmsToken: String) async -> [String: String] {
        let identityToken = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
        var headers: [String: String] = [
            "User-Agent": xcodeUserAgent,
            "Accept": "text/x-xml-plist",
            "Accept-Language": "en-us",
            "X-Apple-Identity-Token": identityToken,
            "X-Apple-I-Identity-Token": identityToken,
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "14.2 (14C18)",
            "X-Mme-Client-Info": identity.clientInfo,
            "X-Apple-I-DSID": dsid,
        ]
        for (k, v) in identity.metaHeaders() { headers[k] = v }
        if let anisetteHeaders = try? await anisette.fetchHeaders() {
            for (k, v) in anisetteHeaders { headers[k] = v }
        }
        return headers
    }

    private func handleTrustedDevice(dsid: String, idmsToken: String) async -> Bool {
        var triggered = false
        for _ in 0..<3 {
            var request = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!)
            for (k, v) in await build2FAHeaders(dsid: dsid, idmsToken: idmsToken) { request.setValue(v, forHTTPHeaderField: k) }
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, [200, 412].contains(http.statusCode) {
                triggered = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard triggered else { return false }

        guard let code = await twoFactorProvider.requestCode(method: "trustedDevice") else { return false }

        var validateRequest = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!)
        for (k, v) in await build2FAHeaders(dsid: dsid, idmsToken: idmsToken) { validateRequest.setValue(v, forHTTPHeaderField: k) }
        validateRequest.setValue(code, forHTTPHeaderField: "Security-Code")
        validateRequest.setValue(code, forHTTPHeaderField: "security-code")

        guard let (_, response) = try? await session.data(for: validateRequest),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - 2FA: SMS (fallback)

    private func handleSMS(dsid: String, idmsToken: String) async -> Bool {
        var phoneId = 1
        var listRequest = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/phone")!)
        for (k, v) in await build2FAHeaders(dsid: dsid, idmsToken: idmsToken) { listRequest.setValue(v, forHTTPHeaderField: k) }
        if let (data, _) = try? await session.data(for: listRequest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let phones = json["trustedPhoneNumbers"] as? [[String: Any]],
           let first = phones.first, let id = first["id"] as? Int {
            phoneId = id
        }

        var smsRequest = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/phone")!)
        smsRequest.httpMethod = "PUT"
        for (k, v) in await build2FAHeaders(dsid: dsid, idmsToken: idmsToken) { smsRequest.setValue(v, forHTTPHeaderField: k) }
        smsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        smsRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["phoneNumber": ["id": phoneId], "mode": "sms"])
        _ = try? await session.data(for: smsRequest)

        guard let code = await twoFactorProvider.requestCode(method: "sms") else { return false }

        var validateRequest = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode")!)
        validateRequest.httpMethod = "POST"
        for (k, v) in await build2FAHeaders(dsid: dsid, idmsToken: idmsToken) { validateRequest.setValue(v, forHTTPHeaderField: k) }
        validateRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        validateRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
            "phoneNumber": ["id": phoneId], "mode": "sms", "securityCode": ["code": code],
        ])

        guard let (_, response) = try? await session.data(for: validateRequest),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
