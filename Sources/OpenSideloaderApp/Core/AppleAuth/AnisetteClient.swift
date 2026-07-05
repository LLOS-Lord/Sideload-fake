import Foundation

/// Lấy "anisette data" — header xác thực dấu vân tay thiết bị mà Apple yêu cầu
/// cho mọi request GSA. Bản thân dữ liệu này KHÔNG tự sinh được trên iOS bằng
/// API công khai — luôn phải xin từ một anisette server (tự host hoặc dùng
/// server cộng đồng), giống hệt cách apple_auth.py làm.
actor AnisetteClient {
    private let officialServersURL = URL(string: "https://servers.sidestore.io")!
    private let defaultServerURL: URL

    private(set) var currentServerURL: URL
    private let session: URLSession

    init(defaultServer: URL = URL(string: "http://127.0.0.1:6969")!, session: URLSession = .shared) {
        self.defaultServerURL = defaultServer
        self.currentServerURL = defaultServer
        self.session = session
    }

    /// Dò danh sách server công khai (nếu có) và chọn cái phản hồi được,
    /// tương đương get_best_anisette_server(). Nếu không dò được, giữ
    /// nguyên currentServerURL đã cấu hình sẵn.
    func selectBestServer() async {
        do {
            let (data, _) = try await session.data(from: officialServersURL)
            struct ServerList: Decodable {
                struct Entry: Decodable { let name: String?; let address: String }
                let servers: [Entry]
            }
            let list = try JSONDecoder().decode(ServerList.self, from: data)
            for entry in list.servers {
                guard let url = URL(string: entry.address) else { continue }
                if await isReachable(url) {
                    currentServerURL = url
                    return
                }
            }
        } catch {
            // Không dò được danh sách công khai — giữ server mặc định.
        }
    }

    private func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 500 < 400
        } catch {
            return false
        }
    }

    /// Tương đương generate_anisette_headers(): GET tới anisette server, trả
    /// về dict header thô (X-Apple-I-MD-M, X-Apple-I-MD, X-Mme-Device-Id...).
    /// Thử tối đa 3 lần, đổi server nếu lỗi liên tục — giống bản Python.
    func fetchHeaders() async throws -> [String: String] {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: currentServerURL)
                request.timeoutInterval = 10
                let (data, _) = try await session.data(for: request)
                let headers = try JSONDecoder().decode([String: String].self, from: data)
                return headers
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await selectBestServer()
                }
            }
        }
        throw AnisetteError.fetchFailedAfterRetries(lastError)
    }

    func setServer(_ url: URL) {
        currentServerURL = url
    }
}

enum AnisetteError: LocalizedError {
    case fetchFailedAfterRetries(Error?)

    var errorDescription: String? {
        switch self {
        case .fetchFailedAfterRetries(let underlying):
            return "Không lấy được dữ liệu Anisette sau 3 lần thử" +
                (underlying.map { ": \($0.localizedDescription)" } ?? ".")
        }
    }
}

/// Header meta đi kèm mọi request GSA — tương đương generate_meta_headers().
/// Sinh mới cho MỖI request (đặc biệt X-Apple-I-Client-Time) chứ không cache.
struct AppleClientIdentity {
    let userId = UUID().uuidString.uppercased()
    var deviceId = UUID().uuidString.uppercased()
    var clientInfo = "<MacBookPro18,3> <Mac OS X;13.4.1;22F8> <com.apple.AOSKit/282 (com.apple.dt.Xcode/3594.4.19)>"

    func metaHeaders() -> [String: String] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        return [
            "X-Apple-I-Client-Time": isoFormatter.string(from: Date()),
            "X-Apple-I-TimeZone": TimeZone.current.identifier,
            "loc": Locale.current.identifier,
            "X-Apple-Locale": Locale.current.identifier,
            "X-Apple-I-MD-RINFO": "17106176",
            "X-Apple-I-MD-LU": Data(userId.utf8).base64EncodedString(),
            "X-Mme-Device-Id": deviceId,
            "X-Apple-I-SRL-NO": "0",
        ]
    }
}
