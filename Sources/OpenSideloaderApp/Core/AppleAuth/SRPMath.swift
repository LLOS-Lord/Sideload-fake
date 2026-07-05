import Foundation
import BigInt
import CryptoKit

/// Cài đặt SRP-6a (RFC 2945 / RFC 5054) bằng BigInt, KHÔNG dùng swift-srp có sẵn.
///
/// LÝ DO KHÔNG DÙNG THẲNG MỘT PACKAGE SRP CÓ SẴN (vd adam-fowler/swift-srp):
/// API bậc cao của các package đó cố định công thức chuẩn
///     x = H(s | H(I || ":" || P))
/// (I = username, P = password). Nhưng GSA của Apple, qua thư viện Python `srp`
/// với cấu hình `srp.no_username_in_x()`, dùng biến thể BỎ username khỏi x:
///     x = H(s | P)
/// và P ở đây không phải mật khẩu gốc mà là kết quả `encrypt_password()`
/// (SHA256 rồi PBKDF2 — xem AppleGSAClient). Không package SRP bậc cao nào cho
/// phép chèn biến thể này từ bên ngoài, nên phải tự viết công thức bằng BigInt.
///
/// ⚠️ MỨC ĐỘ TIN CẬY: đây là phần tôi tự tin nhất về mặt công thức chuẩn (RFC),
/// nhưng KHÔNG có cách nào compile/chạy thử trong sandbox này để xác nhận khớp
/// byte-for-byte với thư viện `srp` (Python) mà bản tham chiếu đang dùng. Vì 1
/// sai lệch nhỏ ở bước hash sẽ khiến toàn bộ xác thực thất bại 100% (không phải
/// lỗi ngẫu nhiên), TRƯỚC KHI dùng thật, hãy tự kiểm chứng bằng cách:
///   1. Thêm print(a.hex), print(A.hex), print(x.hex)... vào CẢ HAI bên
///      (apple_auth.py đang chạy thật + đoạn Swift này) với CÙNG salt/B giả lập
///      (không phải gọi Apple thật), so khớp từng giá trị trung gian.
///   2. Chỉ khi các giá trị trung gian khớp nhau mới thử nối vào luồng thật.
enum SRPMath {

    // RFC 5054 Appendix A — nhóm 2048-bit, đây là hằng số chuẩn công khai,
    // không phải giá trị tự chọn.
    static let N = BigUInt(
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050" +
        "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50" +
        "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8" +
        "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B" +
        "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748" +
        "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861602790" +
        "04E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8" +
        "E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F" +
        "9E4AFF73",
        radix: 16
    )!
    static let g = BigUInt(2)

    private static var nByteCount: Int { (N.bitWidth + 7) / 8 } // 256 cho N 2048-bit

    /// Băm SHA256, trả về BigUInt (dùng cho k, u, x).
    private static func H(_ parts: [Data]) -> Data {
        var hasher = SHA256()
        for p in parts { hasher.update(data: p) }
        return Data(hasher.finalize())
    }

    /// Đệm 1 số về đúng độ dài byte của N (bắt buộc theo RFC2945/5054 trước khi
    /// đưa vào các phép hash liên quan tới k/u/M1 — thiếu bước này là lỗi kinh
    /// điển khiến SRP tự chế "gần đúng nhưng luôn sai").
    private static func pad(_ value: BigUInt) -> Data {
        var bytes = value.serialize()
        if bytes.count < nByteCount {
            bytes = Data(repeating: 0, count: nByteCount - bytes.count) + bytes
        }
        return bytes
    }

    /// k = H(N | PAD(g))  — định nghĩa theo RFC 5054 (khác k=3 của SRP-6 gốc;
    /// tương ứng đúng lúc code Python gọi `srp.rfc5054_enable()`).
    static func computeK() -> BigUInt {
        BigUInt(H([pad(N), pad(g)]))
    }

    /// x = H(PAD(s) | P) — s là salt Apple trả về, P là password ĐÃ được
    /// encrypt_password() xử lý (không phải mật khẩu gốc). KHÔNG có username
    /// trong công thức này (tương ứng `srp.no_username_in_x()`).
    static func computeX(salt: Data, processedPassword: Data) -> BigUInt {
        BigUInt(H([salt, processedPassword]))
    }

    struct ClientKeyPair {
        let a: BigUInt // private
        let A: BigUInt // public = g^a mod N
    }

    static func generateClientKeys() -> ClientKeyPair {
        // a: số ngẫu nhiên riêng tư, ít nhất 256 bit theo khuyến nghị RFC5054.
        var randomBytes = Data(count: 32)
        _ = randomBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        let a = BigUInt(randomBytes)
        let A = g.power(a, modulus: N)
        return ClientKeyPair(a: a, A: A)
    }

    /// u = H(PAD(A) | PAD(B))
    static func computeU(A: BigUInt, B: BigUInt) -> BigUInt {
        BigUInt(H([pad(A), pad(B)]))
    }

    /// S = (B - k*g^x) ^ (a + u*x) mod N — công thức lõi phía client của SRP-6a.
    /// Cần cẩn thận dấu trừ trên BigUInt (không âm): làm phép trừ modulo N để
    /// tránh trap khi B < k*g^x mod N.
    static func computeSharedSecret(
        clientKeys: ClientKeyPair,
        serverPublicKeyB B: BigUInt,
        k: BigUInt,
        x: BigUInt,
        u: BigUInt
    ) -> BigUInt {
        let gx = g.power(x, modulus: N)
        let kgx = (k * gx) % N
        // (B - kgx) mod N, tính an toàn cho số không âm (BigUInt không có âm).
        let base = (B + N - (kgx % N)) % N
        let exponent = clientKeys.a + u * x
        return base.power(exponent, modulus: N)
    }

    /// K = H(S) — pysrp dùng bản đơn giản (hash trực tiếp S đã pad), KHÔNG
    /// dùng kiểu "interleaved hash" T16 mà 1 số thư viện SRP khác (vd JS srp6a)
    /// áp dụng. Nếu bước verify M2 ở AppleGSAClient luôn thất bại dù mọi giá trị
    /// khác đúng, đây là nghi phạm đầu tiên cần đối chiếu lại.
    static func computeSessionKey(sharedSecret S: BigUInt) -> Data {
        H([pad(S)])
    }

    /// M1 theo RFC 2945 §3: H( H(N) XOR H(PAD(g)), H(I), s, A, B, K )
    /// I = username (KHÔNG bị ảnh hưởng bởi no_username_in_x — cờ đó chỉ tác
    /// động tới công thức x, không tác động tới M1).
    static func computeM1(username: String, salt: Data, A: BigUInt, B: BigUInt, sessionKey K: Data) -> Data {
        let hN = H([pad(N)])
        let hg = H([pad(g)])
        var hNxorHg = Data(count: hN.count)
        for i in 0..<hN.count { hNxorHg[i] = hN[i] ^ hg[i] }
        let hI = H([Data(username.utf8)])
        return H([hNxorHg, hI, salt, pad(A), pad(B), K])
    }

    /// M2 kỳ vọng từ server, theo RFC 2945 §3: H(A, M1, K) — dùng để so khớp
    /// với M2 mà Apple trả về (verify_session phía Python).
    static func computeExpectedM2(A: BigUInt, M1: Data, sessionKey K: Data) -> Data {
        H([pad(A), M1, K])
    }
}
