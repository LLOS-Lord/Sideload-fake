# Cấu hình App Shell (Info.plist / Entitlements)

Đây là các key cần thêm vào project Xcode App "vỏ mỏng" (xem README mục 4),
KHÔNG phải thêm vào Package.swift.

## Info.plist

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <!-- Cho phép app kiểm tra xem StosVPN đã cài chưa, qua canOpenURL -->
    <string>stosvpn</string>
</array>

<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <!-- Đổi thành scheme riêng của bạn — dùng để iloader/Safari gọi lại
                 app này sau khi hoàn tất một bước xác thực/refresh -->
            <string>opensideloader</string>
        </array>
    </dict>
</array>

<key>NSAppTransportSecurity</key>
<dict>
    <!-- Cần nếu anisette server bạn tự host chưa có HTTPS hợp lệ khi test local -->
    <key>NSAllowsArbitraryLoads</key>
    <false/>
</dict>
```

## Entitlements (Signing & Capabilities trong Xcode)

- **Personal VPN** — cần nếu app tự kiểm tra/điều khiển trạng thái kết nối tới
  cấu hình VPN của StosVPN qua `NEVPNManager`/`NETunnelProviderManager`. Đây là
  entitlement phổ biến, mọi tài khoản Apple Developer (kể cả free) đều thêm được
  trực tiếp trong Xcode, không cần xin duyệt riêng.
- **Network Extension** (giá trị `packet-tunnel-provider`) — CHỈ cần nếu bạn tự
  viết `NEPacketTunnelProvider` của riêng mình thay vì dùng StosVPN có sẵn. Khi
  đó bạn phải nộp đơn xin Apple duyệt capability này cho App ID của bạn
  (Certificates, Identifiers & Profiles → chọn App ID → Edit → request thêm
  capability), thường cần tài khoản Developer Program trả phí và vài ngày chờ
  duyệt. Không có cách nào bỏ qua bước này dù code có tự viết 100% hay không.
- **Keychain Sharing** — nếu bạn muốn `PairingFileStore` chia sẻ pairing file
  giữa app chính và một app khác (ví dụ một app JIT-helper riêng).

## Bundle ID / Team ID

Không có key cấu hình riêng ở đây — chỉ cần đặt trong Xcode → target → Signing &
Capabilities → chọn Team của bạn, Xcode tự sinh provisioning profile cho account
miễn phí (7 ngày hiệu lực, cần refresh bằng đúng luồng `RefreshCoordinator` đã
viết trong package).
