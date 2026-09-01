import Foundation
@testable import QiCompass

/// 测试专用 DailyReadCounter 工厂(2026-09-01 排查定案):
/// 测试夹具曾以 `DailyReadCounter()` 默认落 `.standard` UserDefaults——配额
/// (10 次/日,按日期 key)在模拟器 app 容器里**跨测试运行持久累积**,当天
/// 多轮全量后 interpret 被 dailyLimitReached 拦截,`DailyFortuneHourUnknownGateTests`
/// 两条「interpret 必须被调用」用例假红(main 同样复现,与业务代码无关)。
/// 本工厂:固定 suite + 创建即 removePersistentDomain → 每个用例从零配额起,
/// 不跨用例/跨运行污染,也不随运行次数堆积 plist。
/// **约束**:同一测试方法内只建一个 counter——所有工厂产品共享同一 suite,
/// 第二次创建会把第一个的已计数一并清零(现有用例均单 counter 或不断言配额)。
extension DailyReadCounter {
    static func makeIsolatedForTesting() -> DailyReadCounter {
        let suiteName = "test.dailyReadCounter.isolated"
        // 固定非空 suiteName 恒可建;失败即夹具装配错误,显式崩不静默回落
        // (回落 .standard 会重新引入跨运行污染,违背本工厂存在意义)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults(suiteName: \(suiteName)) 创建失败(理论不可达)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return DailyReadCounter(defaults: defaults)
    }
}
