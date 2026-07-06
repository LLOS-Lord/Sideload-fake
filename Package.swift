// swift-tools-version: 5.9
import PackageDescription

// Đây là project ĐỘC LẬP — không phải fork. Không có file nguồn nào của
// SideStore/AltStore nằm trong repo này.
//
// FIX lỗi "Undefined symbols" khi build action:
// SideStore/MinimuxerPackage (vendor tại Vendor/MinimuxerPackage, xem
// Scripts/vendor-and-patch-minimuxer.sh) khai báo dependencies: [] — nó CHỈ
// đóng gói xcframework Rust thô, KHÔNG mang theo libimobiledevice/libplist/
// libusbmuxd. Toàn bộ afc_*/idevice_*/lockdownd_*/plist_*/instproxy_*/
// misagent_*/mobile_image_mounter_*/heartbeat_*/debugserver_* linker báo
// thiếu đều thuộc 3 thư viện C đó. Thêm SideStore/iMobileDevice.swift — gói
// mà chính SideStore dùng trong app thật của họ để cấp các symbol này.
let package = Package(
    name: "OpenSideloader",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "OpenSideloaderApp", targets: ["OpenSideloaderApp"]),
    ],
    dependencies: [
        // Toán số lớn (modular exponentiation) cho SRP-6a — MIT license.
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),

        // Tạo CSR khi xin certificate mới từ Apple — Apache 2.0, KHÔNG AGPL.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),

        // minimuxer (Rust, AGPL) — dùng bản vendor CỤC BỘ đã patch 2 lỗi
        // codegen swift-bridge. Thư mục này KHÔNG nằm trong git — CI (và bạn,
        // nếu build local) phải chạy script này TRƯỚC khi build/resolve:
        //   bash Scripts/vendor-and-patch-minimuxer.sh Vendor/MinimuxerPackage
        .package(path: "Vendor/MinimuxerPackage"),

        // MỚI — fix chính. Cấp thật afc_*/idevice_*/lockdownd_*/plist_*/...
        // mà minimuxer cần nhưng không tự mang theo. LGPL-2.1 cho phần C
        // (libimobiledevice/libplist/libusbmuxd), MIT cho wrapper Swift —
        // khác AGPL của minimuxer, xem README mục 2.
        .package(url: "https://github.com/SideStore/iMobileDevice.swift.git", branch: "main"),
        
        // Để đọc/ghi file ZIP (IPA)
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "OpenSideloaderApp",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                "CCommonCryptoShim",

                // Tên product THẬT là "Minimuxer" (xem Package.swift của
                // SideStore/MinimuxerPackage) — KHÔNG phải "MinimuxerFFI".
                .product(name: "Minimuxer", package: "MinimuxerPackage"),

                // MỚI — xem ghi chú fix ở đầu file.
                .product(name: "libimobiledevice", package: "iMobileDevice.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),

        // Shim hệ thống gọi CommonCrypto (AES-CBC) từ Swift qua SPM.
        .systemLibrary(name: "CCommonCryptoShim", pkgConfig: nil),

        .testTarget(
            name: "OpenSideloaderAppTests",
            dependencies: ["OpenSideloaderApp"]
        ),
    ]
)
