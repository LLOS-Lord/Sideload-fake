import Foundation

/// Ngữ cảnh xảy ra lỗi — dùng để chỉnh câu chữ cho hợp tình huống,
/// ví dụ "làm mới app X" khác với "đang cài app mới".
enum ErrorContext {
    case installingApp(String)
    case refreshingApp(String)
    case signingIn
    case repairingConnection
    case general
}

/// Thông điệp lỗi thân thiện, kèm gợi ý hành động cụ thể (không chỉ mô tả lỗi).
/// Đây là phần thay thế cho bảng "Error Codes" khô khan của SideStore —
/// mỗi lỗi kỹ thuật được dịch thành 1-2 câu + một hành động có thể bấm.
struct FriendlyError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suggestedAction: SuggestedAction?

    enum SuggestedAction {
        case repairPairingAndVPN   // gọi AppEnvironment.repairPairingAndVPN()
        case signInAgain
        case switchToWifi
        case updateApp
        case none
    }

    /// Khởi tạo từ lỗi thật do AppleAuthAdapter/DeveloperServicesAPI/MinimuxerFFI ném ra.
    ///
    /// `code` nên được đọc từ `NSError.code` sau khi bridge lỗi Swift-native
    /// (`MinimuxerError`, `ALT*Error`...) sang `NSError`, hoặc bạn có thể sửa
    /// switch bên dưới để so khớp trực tiếp trên enum case thay vì mã số — bảng
    /// mã dưới đây tổng hợp lại từ tài liệu lỗi công khai của SideStore, đã
    /// diễn giải lại bằng lời của tác giả file này, dùng làm điểm khởi đầu.
    init(from error: Error, context: ErrorContext = .general) {
        let code = (error as NSError).code

        switch code {
        case 4, 27:
            // minimuxer: không mở được AFC do pairing record không hợp lệ.
            self.title = "Không kết nối được với máy để cài/làm mới app"
            self.message = "Hồ sơ ghép nối (pairing) giữa app và thiết bị đang không hợp lệ hoặc đã cũ. Đây KHÔNG phải lỗi của app bạn đang cài — chỉ cần tạo lại hồ sơ ghép nối là xong."
            self.suggestedAction = .repairPairingAndVPN

        case 1414:
            self.title = "Chưa có Wi-Fi hoặc VPN cục bộ"
            self.message = "Cần bật Wi-Fi và giữ VPN cục bộ (StosVPN) đang kết nối thì mới cài/làm mới được app. Dữ liệu di động (4G/5G) không dùng được cho việc này."
            self.suggestedAction = .switchToWifi

        case 1412:
            self.title = "Không lấy được dữ liệu xác thực từ máy chủ anisette"
            self.message = "Máy chủ anisette hiện dùng đang không phản hồi. Thử đổi sang máy chủ khác trong Cài đặt."
            self.suggestedAction = .repairPairingAndVPN

        case 3002, 3003:
            self.title = "Sai thông tin đăng nhập Apple ID"
            self.message = "Kiểm tra lại email/mật khẩu. Nếu tài khoản bật xác thực 2 yếu tố, có thể cần tạo mật khẩu dành riêng cho ứng dụng tại appleid.apple.com."
            self.suggestedAction = .signInAgain

        case 1009, 3013:
            self.title = "Đã đăng ký quá nhiều App ID trong 7 ngày"
            self.message = "Tài khoản Apple ID miễn phí chỉ được đăng ký tối đa 10 App ID mỗi 7 ngày. Đợi đến khi hạn mức được làm mới, hoặc dùng Apple ID khác."
            self.suggestedAction = FriendlyError.SuggestedAction.none

        case 1007:
            self.title = "File không đúng định dạng .ipa"
            self.message = "File bạn chọn có vẻ không phải một gói ứng dụng iOS hợp lệ. Thử tải lại file từ nguồn khác."
            self.suggestedAction = FriendlyError.SuggestedAction.none

        default:
            switch context {
            case .installingApp(let name):
                self.title = "Cài đặt \(name) không thành công"
            case .refreshingApp(let name):
                self.title = "Làm mới \(name) không thành công"
            case .signingIn:
                self.title = "Đăng nhập không thành công"
            case .repairingConnection:
                self.title = "Sửa kết nối không thành công"
            case .general:
                self.title = "Có lỗi xảy ra"
            }
            self.message = error.localizedDescription
            self.suggestedAction = FriendlyError.SuggestedAction.none
        }
    }
}
