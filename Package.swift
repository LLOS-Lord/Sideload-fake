// swift-tools-version: 5.9
import PackageDescription

// Đây là project ĐỘC LẬP — không phải fork. Không có file nguồn nào của
// SideStore/AltStore nằm trong repo này.
//
// CẬP NHẬT DEPENDENCY (thay cho StosSign):
// Lớp xác thực Apple ID + Developer Services API giờ được viết mới hoàn toàn
// trong Sources/OpenSideloaderApp/Core/AppleAuth/, dựa trên việc đọc trực tiếp
// mã nguồn thật của một tool Python tương đương (apple_auth.py/developer_api.py)
// — không copy code, chỉ tái hiện lại đúng giao thức bằng Swift. Cả 3 dependency
// của lớp này đều PERMISSIVE (không AGPL):
//   - attaswift/BigInt (MIT)         : toán số lớn cho SRP-6a
//   - apple/swift-certificates (Apache 2.0) : tạo CSR khi xin certificate mới
//   - apple/swift-crypto (Apache 2.0)       : RSA keypair cho CSR (_CryptoExtras)
//   - CommonCrypto (hệ thống)        : AES-CBC cho bước giải mã SPD của GSA
// KHÔNG còn phụ thuộc StosSign/AltSign (AGPL) cho lớp này. minimuxer (AGPL) vẫn
// còn cho lớp AFC/installation_proxy — xem README mục 2 để biết vì sao lớp đó
// khó thay thế hơn. Bước KÝ ipa cuối cùng (sau khi có cert+profile) vẫn là
// TODO — xem IpaCodeSigning trong AppleAuthAdapter.swift và README mục 7.
let package = Package(
    name: "OpenSideloader",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "OpenSideloaderApp", targets: ["OpenSideloaderApp"]),
    ],
    dependencies: [
        // Toán số lớn (modular exponentiation) cho SRP-6a — MIT license.
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        // Tạo CSR (Certificate Signing Request) khi xin certificate mới từ
        // Apple — cả 2 đều của Apple/SSWG, Apache 2.0, KHÔNG phải AGPL.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // minimuxer (Rust, AGPL) — dùng thẳng package SPM chính thức của SideStore
        // thay vì tự khai báo binaryTarget trỏ URL/checksum thủ công. Repo này đã
        // đóng gói sẵn RustXcframework.xcframework NGAY TRONG git (không tải qua
        // mạng lúc resolve), nên `xcodebuild -resolvePackageDependencies` không
        // còn phụ thuộc vào 1 URL Release do mình tự host + tính checksum tay
        // (đây chính là nguyên nhân job "Resolve Swift Package dependencies" lỗi
        // exit code 74 trước đây: URL cũ chứa "VERSION" theo nghĩa đen, 404).
        // Ghim đúng 1 commit (thay vì `branch: "main"`) — KHÔNG phải để né lỗi gì
        // trong repo đó, mà để bớt 1 biến số khi debug: nếu resolve vẫn lỗi, chắc
        // chắn không phải do nhánh main đổi commit giữa các lần chạy CI.
        .package(url: "https://github.com/SideStore/MinimuxerPackage.git", revision: "7a73cc752eb4e1efcbda260d0854f3f3a3c8436d"),
    ],
    targets: [
        .target(
            name: "OpenSideloaderApp",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                "CCommonCryptoShim",
                .product(name: "Minimuxer", package: "MinimuxerPackage"),
            ]
        ),

        // Shim hệ thống để gọi CommonCrypto (AES-CBC) từ Swift qua SPM.
        // CommonCrypto có sẵn trên mọi thiết bị Apple, không cần tải thêm gì.
        .systemLibrary(name: "CCommonCryptoShim", pkgConfig: nil),

        .testTarget(
            name: "OpenSideloaderAppTests",
            dependencies: ["OpenSideloaderApp"]
        ),
    ]
)
