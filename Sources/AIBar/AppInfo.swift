import Foundation

enum AppInfo {
    /// CFBundleShortVersionString, e.g. "1.1". Unbundled runs (`make snapshot`, `swift run`) have no
    /// Info.plist in the bundle, so they read the one in Resources/ when run from the repository.
    static let version: String = {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return v
        }
        let plist = URL(fileURLWithPath: "Resources/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let v = dict["CFBundleShortVersionString"] as? String {
            return v
        }
        return "dev"
    }()
}
