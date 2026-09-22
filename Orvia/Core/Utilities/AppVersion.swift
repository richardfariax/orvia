import Foundation

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var displayLabel: String {
        "v\(marketing) (\(build))"
    }

    /// `true` se `candidate` (ex.: `2.1.0` ou `v2.1.0`) for estritamente mais novo que `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(normalize(candidate), normalize(current)) == .orderedDescending
    }

    private static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        if let dash = value.firstIndex(of: "-") {
            value = String(value[..<dash])
        }
        return value
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a > b ? .orderedDescending : .orderedAscending
            }
        }
        return .orderedSame
    }
}
