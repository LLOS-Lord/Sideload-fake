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

## 4. Việc còn cần làm (đánh dấu TODO trong code)

Sau khi port `apple_auth.py`/`developer_api.py`, phần TODO còn lại đã thu hẹp
đáng kể — gần như chỉ còn ở lớp AFC (minimuxer) và bước ký ipa cuối cùng:

- **`AppleAuthAdapter.swift` → `IpaCodeSigning`**: đây là ranh giới còn lại lớn
  nhất. Cần 1 trong 2 hướng: (a) build lại lõi ký của `zsign` (C++, MIT) thành
  static library rồi gọi qua bridging header — KHÔNG dùng subprocess vì
  iOS không cho phép; (b) viết signer CMS thuần Swift bằng Security framework.
  Cho tôi biết hướng nào bạn muốn, tôi port tiếp.
- **`DeveloperServicesAPI.createCertificate()`**: dùng `swift-certificates` để
  tạo CSR — shape API đã xác nhận qua ví dụ thật, nhưng case
  `.sha256WithRSAEncryption` cho khoá RSA CHƯA được xác nhận trực tiếp, để
  Xcode autocomplete gợi ý nếu sai tên.
- **`MinimuxerBridge.swift`**: nối hàm FFI thật — đã xác nhận CHÍNH XÁC tên hàm
  Rust gốc (`yeet_app_afc`, `install_ipa`, `remove_app`, `start`,
  `test_device_connection`...) từ `src/install.rs`/`src/muxer.rs`/`src/device.rs`
  của file bạn gửi; chỉ còn cần khớp lại chữ ký Swift chính xác mà
  `swift-bridge` sinh ra sau khi build (xem Generated Interface trong Xcode).
- **`PairingFileStore`**: lưu/đọc pairing file bằng Keychain thay vì để trống.
- **`NEVPNStatusReader`**: load `NETunnelProviderManager` thật của StosVPN.
- **2FA UI thật**: `SwiftUITwoFactorPrompt` đang trả `nil` — nối với 1 sheet
  SwiftUI hỏi mã 6 số (SettingsView đã có khung `SignInSheet`, chỉ cần thêm
  bước hiện sheet khi `AppleGSAClient` báo cần 2FA).

## 5. Gói SPM này thành app chạy được trên iPhone

SPM package không tự tạo ra một `.app` cài lên máy được — cần một Xcode App
project "vỏ mỏng" bọc ngoài:

1. Xcode → File → New → Project → iOS App, đặt tên/bundle id của bạn
2. File → Add Package Dependencies... → Add Local... → chọn thư mục `OpenSideloader` này
3. Xoá file `ContentView.swift`/`App.swift` mặc định Xcode tạo ra (logic thật đã
   nằm trong package, không cần trùng)
4. Trong target App, mục Signing & Capabilities: thêm capability **Personal VPN**
   (không phải NetworkExtension packet-tunnel-provider, trừ khi bạn tự làm VPN
   thay vì dùng StosVPN có sẵn)
5. Info.plist: thêm các key theo `APP_SHELL.md`

## 6. Thiết lập minimuxer (binary target)

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

## 7. Vì sao thiết kế này giúp fix lỗi AFC

Lỗi *"AFC was unable to manage files on the device"* — đã xác nhận CHÍNH XÁC từ
`src/afc_file_manager.rs`: xảy ra khi `AfcClient::start_service` thất bại ngay
sau khi lockdownd xác thực pairing record, tức là **pairing record hỏng/không
khớp thiết bị**, không phải lỗi logic cài đặt của app. `MinimuxerDeviceAdapter`
(struct `PairingFileStore`) và `SettingsView` (`PairingTroubleshootView`) gộp
quy trình xoá + tạo lại pairing record + kiểm tra VPN thành **một nút bấm**.
Nếu nút đó vẫn lỗi, dùng `make_pair_file.py` (mục 3) để tạo pairing file mới từ
Termux/PC rồi import thủ công qua Files app — đây là cách chắc chắn nhất trên
iOS ≤ 17.3.
