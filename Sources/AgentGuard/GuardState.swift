import Foundation

enum GuardState: Equatable {
    case inactive
    case guarding
    case authenticating
    case recoveryFailed

    var statusText: String {
        switch self {
        case .inactive:
            return "未启用"
        case .guarding:
            return "托管中：按实体空格键解除"
        case .authenticating:
            return "正在验证：GUI 输入已暂停"
        case .recoveryFailed:
            return "托管恢复异常：请重试验证"
        }
    }
}
