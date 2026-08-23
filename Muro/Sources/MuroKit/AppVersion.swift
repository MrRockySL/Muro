import Foundation

/// Compares dotted version strings.
///
/// It lives in MuroKit rather than in the app so it can be tested. The one
/// mistake this must never make is treating 1.10 as older than 1.9, which is
/// exactly what comparing the strings would do, and the failure would be
/// invisible: every install would simply stop being told about updates.
public enum AppVersion {
    /// True when `candidate` is strictly newer than `current`. Missing
    /// components count as zero, so "2" and "2.0.0" are the same version.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate)
        let right = components(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Tolerates a leading "v", since that is how the release tags are
    /// written on GitHub.
    private static func components(_ version: String) -> [Int] {
        let trimmed = version.lowercased().hasPrefix("v")
            ? String(version.dropFirst())
            : version
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }
}
