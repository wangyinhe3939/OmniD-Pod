import Foundation

enum OffKeyL10n {
    static func text(_ key: String, fallback: String) -> String {
        NSLocalizedString(
            key,
            tableName: "OffKey",
            bundle: .main,
            value: fallback,
            comment: ""
        )
    }
}
