import Foundation

public enum EngineLog {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String) {
        print("[\(formatter.string(from: Date()))] \(message)")
        fflush(stdout)
    }
}
