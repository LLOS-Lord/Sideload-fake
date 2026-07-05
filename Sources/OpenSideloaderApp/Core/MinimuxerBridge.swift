import Foundation
import MinimuxerFFI

/// Lớp bọc mỏng quanh các hàm FFI mà `swift-bridge` sinh ra từ crate Rust của
/// minimuxer. KHÔNG phải TODO nữa — tên hàm/tham số bên dưới đối chiếu trực
/// tiếp với khối `#[swift_bridge::bridge] mod ffi { extern "Rust" { ... } }`
/// thật trong mã nguồn bạn gửi (`src/install.rs`, `src/muxer.rs`,
/// `src/device.rs`, `src/provision.rs`, `src/lib.rs`):
///
/// ```rust
/// fn yeet_app_afc(bundle_id: String, ipa_bytes: &[u8]) -> Result<(), Errors>;
/// fn install_ipa(bundle_id: String) -> Result<(), Errors>;
/// fn remove_app(bundle_id: String) -> Result<(), Errors>;
/// fn start(pairing_file: String, log_path: String) -> Result<(), Errors>;
/// fn target_minimuxer_address();
/// fn fetch_udid() -> Option<String>;
/// fn test_device_connection() -> bool;
/// fn install_provisioning_profile(profile: &[u8]) -> Result<(), Errors>;
/// fn remove_provisioning_profile(id: String) -> Result<(), Errors>;
/// fn describe_error(error: Errors) -> String;
/// fn ready() -> bool;
/// fn set_debug(debug: bool);
/// ```
///
/// ⚠️ MỨC ĐỘ TIN CẬY — đọc trước khi build:
/// Tên hàm và kiểu tham số ở trên là THẬT (đọc trực tiếp từ file bạn gửi, không
/// đoán). Phần CHƯA chắc chắn 100% là cú pháp Swift chính xác mà swift-bridge
/// sinh ra cho 2 trường hợp:
///   1. `Result<(), Errors>` → có thể lộ ra Swift dưới dạng hàm `throws` trực
///      tiếp (bản swift-bridge mới) HOẶC dưới dạng `RustResult<(), MinimuxerError>`
///      cần gọi thêm `.toThrowingResult()`/tương tự để unwrap (bản cũ hơn).
///      Code bên dưới viết theo hướng (1) — nếu Xcode báo lỗi kiểu, khả năng
///      cao chỉ cần thêm `.get()`/`try result.toThrowingResult()` sau lời gọi,
///      xem "Generated Interface" của MinimuxerFFI trong Xcode để biết chính xác.
///   2. `&[u8]` tham số → viết theo pattern `UnsafeBufferPointer<UInt8>` mà
///      file `generated/minimuxer-helpers.swift` bạn gửi định nghĩa qua
///      `RustByteSlice`/`.toRustByteSlice()`. Nếu tên hàm helper khác đi ở
///      bản bạn build, sửa lại đúng 1 chỗ trong `withByteSlice` bên dưới.
enum MinimuxerBridge {

    // MARK: - Lifecycle

    static func targetMinimuxerAddress() {
        target_minimuxer_address()
    }

    static func startMuxer(pairingFileContents: String, logPath: String) async throws {
        try start(pairingFileContents, logPath)
    }

    static func isReady() -> Bool {
        ready()
    }

    static func setDebugLogging(_ enabled: Bool) {
        set_debug(enabled)
    }

    static func describe(_ error: MinimuxerError) -> String {
        describe_error(error)
    }

    // MARK: - Device

    static func fetchUDID() -> String? {
        fetch_udid()
    }

    static func testConnection() -> Bool {
        test_device_connection()
    }

    // MARK: - Install / uninstall (nguồn gốc lỗi "AFC was unable to manage files")

    /// Tương ứng `yeet_app_afc` + `install_ipa` trong install.rs — Rust tách 2
    /// bước (đẩy byte ipa vào PublicStaging qua AFC, rồi mới gọi
    /// installation_proxy cài thật) nên ở đây gọi tuần tự đúng thứ tự đó thay
    /// vì gộp làm 1, để nếu lỗi xảy ra ở bước AFC thì phân biệt được với lỗi
    /// ở bước installation_proxy.
    static func installApp(bundleID: String, ipaData: Data) async throws {
        let bytes = [UInt8](ipaData)
        try withByteSlice(bytes) { slice in
            try yeet_app_afc(bundleID, slice)
        }
        try install_ipa(bundleID)
    }

    static func uninstallApp(bundleID: String) async throws {
        try remove_app(bundleID)
    }

    // MARK: - Provisioning profile (misagent) — dùng khi chỉ cần thay profile
    // mà không cài lại toàn bộ ipa (ví dụ sau khi refresh certificate).

    static func installProvisioningProfile(_ profileData: Data) async throws {
        let bytes = [UInt8](profileData)
        try withByteSlice(bytes) { slice in
            try install_provisioning_profile(slice)
        }
    }

    static func removeProvisioningProfile(id: String) async throws {
        try remove_provisioning_profile(id)
    }

    // MARK: - Helper nội bộ

    /// Gói `[UInt8]` thành `UnsafeBufferPointer<UInt8>` đúng vòng đời cho lời
    /// gọi FFI — tách riêng 1 chỗ để nếu swift-bridge đổi tên helper
    /// (`RustByteSlice`, `.toRustByteSlice()`...) thì chỉ cần sửa Ở ĐÂY.
    private static func withByteSlice<R>(_ bytes: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer(body)
    }
}
