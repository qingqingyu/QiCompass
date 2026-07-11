import Foundation
import os

/// 统一日志封装(原生 os.Logger,不引入第三方库)。
/// 按 subsystem 分 category,便于 Console.app 过滤。
enum AppLogger {
    private static let subsystem = "com.qicompass.app"

    static let networking = Logger(subsystem: subsystem, category: "networking")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let debug = Logger(subsystem: subsystem, category: "debug")

    /// 测量闭包耗时并记录(毫秒),用于 API / SwiftData 操作。
    static func measure<T>(
        _ logger: Logger,
        operation: String,
        context: [String: String] = [:],
        body: () async throws -> T
    ) async throws -> T {
        let start = ContinuousClock().now
        do {
            let result = try await body()
            let elapsed = start.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            logger.info("op=\(operation, privacy: .public) elapsed_ms=\(ms) \(context.logKV, privacy: .public)")
            return result
        } catch {
            let elapsed = start.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            logger.error("op=\(operation, privacy: .public) elapsed_ms=\(ms) failed error=\(String(describing: error), privacy: .public) \(context.logKV, privacy: .public)")
            throw error
        }
    }
}

private extension [String: String] {
    /// 将 context dict 编为 "key=value key=value" 字符串供日志输出。
    var logKV: String {
        isEmpty ? "" : map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}
