import Foundation
import CryptoKit

/// CryptoKit không có PBKDF2 sẵn (chỉ có HMAC/hash), nên viết tay theo đúng
/// RFC 2898 (PBKDF2), dùng HMAC-SHA256 làm PRF — tương đương
/// `hashlib.pbkdf2_hmac("sha256", ...)` phía Python (apple_auth.py, hàm
/// `encrypt_password`).
///
/// Thuật toán chuẩn, không có phần nào đặc thù Apple ở đây — phần đặc thù nằm
/// ở AppleGSAClient (thứ tự SHA256 rồi mới PBKDF2, và encode hex cho biến thể
/// "s2k_fo").
enum PBKDF2 {
    static func sha256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let hLen = 32 // SHA256 output size
        let blockCount = Int(ceil(Double(keyLength) / Double(hLen)))

        var derivedKey = Data()
        derivedKey.reserveCapacity(blockCount * hLen)

        for blockIndex in 1...blockCount {
            var blockIndexBE = UInt32(blockIndex).bigEndian
            var salt_i = salt
            withUnsafeBytes(of: &blockIndexBE) { salt_i.append(contentsOf: $0) }

            var u = hmac(key: password, data: salt_i)
            var t = u

            if iterations > 1 {
                for _ in 2...iterations {
                    u = hmac(key: password, data: u)
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }

            derivedKey.append(t)
        }

        return derivedKey.prefix(keyLength)
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }
}
