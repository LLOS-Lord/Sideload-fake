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
    ],
    targets: [
        .target(
            name: "OpenSideloaderApp",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                "CCommonCryptoShim",
                "MinimuxerFFI",
            ]
        ),

        // Shim hệ thống để gọi CommonCrypto (AES-CBC) từ Swift qua SPM.
        // CommonCrypto có sẵn trên mọi thiết bị Apple, không cần tải thêm gì.
        .systemLibrary(name: "CCommonCryptoShim", pkgConfig: nil),

        // minimuxer là Rust — không có bản SPM thuần Swift. Cách dùng KHÔNG cần
        // fork/tự build: tải file .xcframework đã build sẵn từ trang Releases
        // của https://github.com/SideStore/minimuxer (hoặc build từ mã nguồn gốc
        // bằng `cargo build --target aarch64-apple-ios` rồi đóng gói xcframework,
        // xem README mục 3) và khai báo binaryTarget trỏ tới file/URL đó.
        // Điền lại url + checksum thật trước khi build — 2 giá trị placeholder
        // dưới đây CHƯA dùng được.
        .binaryTarget(
            name: "MinimuxerFFI",
            url: "https://github.com/SideStore/minimuxer/releases/download/VERSION/minimuxer.xcframework.zip",
            checksum: "REPLACE_WITH_REAL_CHECKSUM_FROM_RELEASE_PAGE"
        ),

        .testTarget(
            name: "OpenSideloaderAppTests",
            dependencies: ["OpenSideloaderApp"]
        ),
    ]
)
