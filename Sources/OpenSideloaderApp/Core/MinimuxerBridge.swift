import Foundation
import MinimuxerFFI

/// Lớp bọc mỏng, TỰ VIẾT, quanh các hàm FFI thô mà `swift-bridge` sinh ra từ
/// crate Rust của minimuxer. Mục đích: phần còn lại của OpenSideloaderCore chỉ
/// cần gọi `MinimuxerBridge.installApp(...)` thay vì nhớ tên/tham số chi tiết
/// của từng hàm FFI, và có một chỗ duy nhất để cập nhật khi API FFI đổi version.
///
/// Thân hàm bên dưới là TODO — điền lời gọi thật sau khi mở interface sinh ra
/// của MinimuxerFFI trong Xcode (⌘-click vào `import MinimuxerFFI` hoặc xem tab
/// "Generated Interface").
enum MinimuxerBridge {

    static func installApp(ipaData: Data) async throws {
        throw MinimuxerBridgeError.notWiredYet(function: "installApp")
    }

    static func uninstallApp(bundleID: String) async throws {
        throw MinimuxerBridgeError.notWiredYet(function: "uninstallApp")
    }

    static func generatePairingFile() async throws -> Data {
        throw MinimuxerBridgeError.notWiredYet(function: "generatePairingFile")
    }

    static func startMuxer() async throws {
        throw MinimuxerBridgeError.notWiredYet(function: "startMuxer")
    }
}

enum MinimuxerBridgeError: LocalizedError {
    case notWiredYet(function: String)

    var errorDescription: String? {
        switch self {
        case .notWiredYet(let function):
            return "MinimuxerBridge.\(function) chưa được nối với hàm FFI thật. Xem comment đầu file MinimuxerBridge.swift."
        }
    }
}
