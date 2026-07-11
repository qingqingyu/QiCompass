import Foundation

/// 四态加载枚举(loading / empty / error / success),所有列表/详情路径复用。
/// 错误显式传播:失败时携带原始 error,UI 层展示错误卡而非静默。
enum LoadingState<Value> {
    case loading
    case empty
    case error(Error)
    case success(Value)

    /// 便利:是否处于 loading。
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// 便利:是否成功,若是返回关联值。
    var value: Value? {
        if case .success(let v) = self { return v }
        return nil
    }
}
