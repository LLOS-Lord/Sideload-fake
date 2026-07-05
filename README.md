# OpenSideloader

Project **độc lập, kiến trúc và code mới hoàn toàn** — không fork, không copy file
nguồn nào từ SideStore/AltStore. Lớp xác thực Apple ID + Developer Services API
được **viết lại hoàn toàn bằng Swift**, đối chiếu logic từ một tool Python tham
khảo (không copy code — hai ngôn ngữ khác nhau, phải viết lại). Lớp AFC/pairing
vẫn dùng `minimuxer` (Rust, binary target) vì đây là phần khó thay thế nhất — xem
mục 2.

## 1. Kiến trúc

```
OpenSideloader/
  Package.swift                       ← dependency: BigInt, swift-certificates,
                                         swift-crypto (đều permissive) + MinimuxerFFI (AGPL, binary)
  Sources/OpenSideloaderApp/
    App.swift                         ← entry point, AppEnvironment (state toàn cục)
    Core/
      CoreProtocols.swift             ← protocol tự định nghĩa: DeviceConnecting, AppSigning,
                                         AppInstalling, PairingFileManaging
      MinimuxerDeviceAdapter.swift    ← implement DeviceConnecting/AppInstalling/PairingFileManaging
      MinimuxerBridge.swift           ← wrapper Swift mỏng quanh hàm FFI thô của minimuxer
      SideloadedApp.swift             ← model dữ liệu
      FriendlyError.swift             ← dịch lỗi kỹ thuật (kể cả lỗi AFC) sang thông điệp dễ hiểu
      RefreshCoordinator.swift        ← lên lịch refresh app trước khi hết hạn 7 ngày
      AppleAuth/
        AppleAuthAdapter.swift        ← implement AppSigning, điều phối 2 client bên dưới
        AppleGSAClient.swift          ← xác thực Apple ID (SRP-6a + GrandSlam), tự viết
        DeveloperServicesAPI.swift    ← App ID / certificate / provisioning profile, tự viết
        SRPMath.swift                 ← toán SRP-6a thô bằng BigInt (RFC 2945/5054)
        PBKDF2.swift                  ← PBKDF2-HMAC-SHA256 viết tay (CryptoKit không có sẵn)
        AnisetteClient.swift          ← lấy anisette data từ 1 server (tự host hoặc cộng đồng)
    UI/
      MyApps/MyAppsView.swift         ← danh sách app + hạn dùng + nút refresh
      Install/InstallView.swift       ← cài ipa mới (chọn file hoặc URL nguồn)
      Settings/SettingsView.swift     ← đăng nhập Apple ID, trạng thái VPN, sửa lỗi AFC 1-chạm
```

## 2. Bảng dependency — vì sao chỉ còn 1 chỗ dính AGPL

| Dependency | Vai trò | Giấy phép |
|---|---|---|
| `attaswift/BigInt` | Toán số lớn cho SRP-6a | MIT |
| `apple/swift-certificates` | Tạo CSR khi xin certificate mới | Apache 2.0 |
| `apple/swift-crypto` (`_CryptoExtras`) | Sinh khoá RSA cho CSR | Apache 2.0 |
| CommonCrypto (hệ thống) | AES-CBC giải mã trường `spd` của GSA | Có sẵn trên máy Apple |
| `SideStore/minimuxer` | AFC/lockdown/installation_proxy qua VPN loopback | **AGPL-3.0** |
| StosVPN (app riêng, không nhúng code) | Tạo tunnel loopback để minimuxer hoạt động | AGPL-3.0 (nhưng KHÔNG link vào binary của bạn — xem dưới) |

**Thay đổi quan trọng so với bản trước:** toàn bộ lớp xác thực Apple ID + xin
certificate/provisioning profile giờ **không còn phụ thuộc gì AGPL** — được viết
lại bằng Swift, đối chiếu logic từ file `apple_auth.py`/`developer_api.py` bạn
gửi (2 file đó tự thực nghiệm lại giao thức công khai của Apple, không phải mã
nguồn phái sinh từ AltSign). Vùng AGPL duy nhất còn lại là `minimuxer` — vì đây
là thứ MỞ ĐƯỜNG cho việc chạy trên chính điện thoại không cần máy tính (giả lập
usbmuxd trong sandbox qua VPN loopback), và không có bản thay thế permissive nào
tương đương về độ ổn định. StosVPN chạy như **app cài riêng**, không compile
chung vào binary của bạn, nên rủi ro AGPL của riêng nó thấp hơn nhiều so với
minimuxer (vốn phải link tĩnh vào app bạn phân phối).

> Vẫn nhắc lại: đây không phải tư vấn pháp lý. Nếu mục tiêu là phát hành
> closed-source, nhờ luật sư xem lại việc bạn có link `MinimuxerFFI` tĩnh vào
> app phân phối cho người dùng hay không.

## 3. Phát hiện quan trọng từ file bạn gửi: 2 kiến trúc khác nhau

`ios_sideload_tool` (Python, chạy trên Termux/PC) và `minimuxer` (Rust, chạy
TRONG app iOS) giải quyết 2 bài toán khác nhau, không thay thế nhau:

- **`device_pairing.py` / `make_pair_file.py`** mở kết nối tới usbmuxd **thật**
  (2 thiết bị vật lý khác nhau qua USB) — đây là cơ chế của kiến trúc companion
  cổ điển (AltServer đời đầu), **không chạy được bên trong sandbox của 1 app
  iOS** (không có "thiết bị thứ 2" để pair khi app tự chạy trên chính điện thoại).
- **`minimuxer`** tồn tại chính vì lý do đó: nó giả lập usbmuxd ngay bên trong
  app, nói chuyện với chính thiết bị qua VPN loopback của StosVPN — đây là cách
  duy nhất hiện có để làm điều "companion" làm, nhưng chạy untethered.

**Giá trị dùng ngay hôm nay, không cần chờ code Swift:** `make_pair_file.py`
chạy trên Termux/PC tạo ra đúng file `ALTPairingFile.mobiledevicepairing` mà
SideStore (và `MinimuxerDeviceAdapter` trong project này) cần — độc lập hoàn
toàn với việc bạn có build xong app Swift hay chưa. Bạn đã xác nhận thiết bị
đang ở iOS ≤ 17.3 nên cơ chế PKI/X.509 cổ điển mà file đó dùng vẫn còn đúng
(từ 17.4 Apple đổi sang RemotePairing/Curve25519, file đó không hỗ trợ).

**`zsign`** (binary trong `ios_sideload_tool`) là **MIT license** — tin tốt nếu
sau này bạn muốn thay thế bước ký ipa mà không dính AGPL. Nhưng nó là 1
subprocess CLI, mà app iOS không có quyền `fork`/`exec` — xem mục 4.

## 4. Việc còn cần làm — đã thu hẹp rất nhiều sau lượt này

Đã chuyển từ TODO rỗng sang code thật trong lượt vừa rồi:
`MinimuxerBridge` (gọi đúng tên hàm FFI xác nhận từ source), `PairingFileStore`
(Keychain thật), `NEVPNStatusReader` (NETunnelProviderManager thật), 2FA
(`TwoFactorPromptCoordinator` + sheet SwiftUI thật, không còn trả `nil`),
`InstalledAppsStore` (tự lưu danh sách app vì minimuxer không hỗ trợ liệt kê),
và luồng `resign → ipa đã ký → install` giờ truyền đúng file thay vì `/dev/null`.
Đồng thời sửa 1 lỗi kiến trúc quan trọng: **minimuxer KHÔNG có khả năng tự sinh
pairing file mới** (đã rà toàn bộ mã nguồn, không có hàm FFI nào làm việc đó) —
`PairingFileManaging` đổi từ "tự sinh" sang "nhập file có sẵn"
(`importPairingFile(from:)`), đúng với thực tế bạn sẽ dùng `make_pair_file.py`
(mục 3) để tạo file đó từ Termux/PC.

**Còn lại, theo độ ưu tiên:**

- **`IpaCodeSigning` (`AppleAuthAdapter.swift`)** — RANH GIỚI LỚN NHẤT còn lại,
  vẫn throw ngay lập tức. Không có bước này, chuỗi resign→install không thể
  hoàn tất dù mọi phần khác chạy đúng. Cần 1 trong 2 hướng: (a) build lõi ký
  của `zsign` (C++, MIT) thành static library gọi qua bridging header — KHÔNG
  dùng subprocess vì iOS không cho phép; (b) viết signer CMS thuần Swift bằng
  Security framework. Cho tôi biết hướng nào để port tiếp.
- **`MinimuxerDeviceAdapter.readBundleIdentifier(fromIpaAt:)`**: đang trả `nil`
  luôn (đoán bundle id từ tên file) — cần 1 thư viện đọc zip (ví dụ
  ZIPFoundation) để đọc đúng CFBundleIdentifier từ `Payload/*.app/Info.plist`.
- **`DeveloperServicesAPI.createCertificate()`**: case `.sha256WithRSAEncryption`
  cho khoá RSA CHƯA được xác nhận trực tiếp qua tài liệu — để Xcode autocomplete
  gợi ý nếu sai tên.
- **`MinimuxerBridge`**: tên hàm Rust đã xác nhận chính xác, nhưng CÁCH
  swift-bridge lộ `Result<(), Errors>` ra Swift (throws trực tiếp hay
  `RustResult` cần unwrap) chưa xác nhận — xem comment đầu file, chỉ cần sửa
  1 chỗ nếu Xcode báo lỗi kiểu.
- **Chưa build/test lần nào** — toàn bộ nhận định "đúng" ở trên dựa trên đối
  chiếu mã nguồn tĩnh, không phải chạy thật (không có Xcode/thiết bị trong môi
  trường của tôi).

## 5. App shell (`App/`) — đã tạo, dùng XcodeGen thay vì tự viết pbxproj

`App/project.yml` sinh `.xcodeproj` bằng [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(MIT) — KHÔNG hand-write `project.pbxproj` vì định dạng đó rất dễ hỏng và không
kiểm tra được nếu không có Xcode thật:

```bash
brew install xcodegen
cd App
xcodegen generate
open OpenSideloader.xcodeproj
```

Cấu trúc `App/`: `project.yml` (spec), `Info.plist`, `OpenSideloader.entitlements`
(Personal VPN — xem comment trong file, chưa xác nhận 100% key/value đúng),
`Assets.xcassets` (icon placeholder tự sinh, THAY bằng icon thật trước khi phát
hành), `Sources/AppShellBootstrap.swift` (file rỗng, chỉ để target có ít nhất 1
source file — logic thật nằm trong package `Sources/OpenSideloaderApp/`).

Trong Xcode, Signing & Capabilities: chọn Team của bạn, KHÔNG cần thêm
NetworkExtension packet-tunnel-provider (chỉ cần nếu bạn tự viết VPN thay vì
dùng StosVPN có sẵn).

## 6. CI: `.github/workflows/build.yml`

Job `build-ipa` chạy `xcodegen generate` → `xcodebuild archive` (không ký, vì
CI không có chứng chỉ Apple thật) → fakesign bằng `ldid` → đóng gói `.ipa` →
upload artifact. Đây là pipeline CHƯA CHẠY THỬ (không có macOS trong môi trường
của tôi) — nhiều khả năng cần chỉnh sau lần chạy CI đầu tiên, xem comment
"khả năng cần sửa" ngay trong file workflow.

## 7. Thiết lập minimuxer (binary target)

`minimuxer` là Rust, không có bản SPM Swift thuần. Cách dùng mà KHÔNG cần fork
mã nguồn của họ:

```bash
git clone https://github.com/jkcoxson/minimuxer.git
cd minimuxer
make xcframework   # hoặc: make zip để có sẵn file .zip đem upload lên GitHub Release của BẠN
```

Sau đó:
1. Upload file `.xcframework.zip` lên GitHub Release của repo `OpenSideloader`
2. Lấy checksum: `swift package compute-checksum minimuxer.xcframework.zip`
3. Điền `url` + `checksum` thật vào `binaryTarget` trong `Package.swift`

## 8. Vì sao thiết kế này giúp fix lỗi AFC

Lỗi *"AFC was unable to manage files on the device"* — đã xác nhận CHÍNH XÁC từ
`src/afc_file_manager.rs`: xảy ra khi `AfcClient::start_service` thất bại ngay
sau khi lockdownd xác thực pairing record, tức là **pairing record hỏng/không
khớp thiết bị**, không phải lỗi logic cài đặt của app. `SettingsView` →
`PairingTroubleshootView` tách rõ 2 bước thật: (1) xoá pairing cũ trong Keychain
— tự động; (2) nhập pairing file mới do bạn tự tạo bằng `make_pair_file.py`
(mục 3, Termux/PC qua USB thật) — KHÔNG còn giả vờ "1 nút bấm là xong" vì
minimuxer thật sự không có khả năng tự sinh file đó trên chính thiết bị.
