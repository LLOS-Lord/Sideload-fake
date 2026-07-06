import Foundation
import ZIPFoundation

enum BundleIdentifierReaderError: Error {
    case infoPlistNotFound
    case invalidInfoPlist
}

struct BundleIdentifierReader {
    /// Đọc CFBundleIdentifier từ Info.plist bên trong file .ipa
    /// Cấu trúc IPA: Payload/<App>.app/Info.plist
    static func readBundleIdentifier(fromIpaPath path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw BundleIdentifierReaderError.infoPlistNotFound
        }

        // Tìm Info.plist trong thư mục Payload/*.app/
        // Chúng ta tìm file kết thúc bằng "Payload/" + một cái gì đó + ".app/Info.plist"
        let infoPlistEntry = archive.first { entry in
            let path = entry.path
            return path.hasPrefix("Payload/") && path.hasSuffix(".app/Info.plist") && path.components(separatedBy: "/").count == 3
        }

        guard let entry = infoPlistEntry else {
            throw BundleIdentifierReaderError.infoPlistNotFound
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            throw BundleIdentifierReaderError.invalidInfoPlist
        }

        return bundleID
    }
}
