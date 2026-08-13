import Foundation
import SwiftData

/// Entitlement(M3 后端付费系统客户端镜像)。
///
/// 对齐 MONETIZATION.md §客户端 SwiftData schema。
/// 一行 = 一笔 Apple transactionId 对应的命盘付费授权。
///
/// 字段策略:
/// - `transactionId`:Apple JWS transactionId(全局唯一),作 PK
/// - `contentHash`:绑定到命盘(`ChartSnapshot.contentHash` 软引用)
/// - `module`:**基础名**(`bazi_deep` / `compatibility`),不含 `_free`/`_paid` 后缀
///   (entitlement 是"用户买过该命盘付费内容",与具体 prompt 版本无关)
/// - `userLocalId`:客户端 UUID(未登录兜底维度,见 UserIdentity)
/// - `userId`:后端 `qicompass_user.id`(Slice 3 加,登录后写入;老数据 / 未登录为 nil)
///   SwiftData lightweight migration 自动加列(iOS 17.2+ 支持)
/// - `isActive`:退款/撤销后置 false(M2c webhook 写,或本地手动 deactivate)
///
/// **不加** `refundedAt` / `revokedAt`(后端职责,iOS 只关心 `isActive`)
@Model
final class Entitlement {
    @Attribute(.unique) var transactionId: String
    var productId: String
    var contentHash: String
    var module: String
    var userLocalId: String
    var userId: String?
    var purchasedAt: Date
    var originalPurchaseDate: Date
    var isActive: Bool

    init(
        transactionId: String,
        productId: String,
        contentHash: String,
        module: String,
        userLocalId: String,
        userId: String? = nil,
        purchasedAt: Date,
        originalPurchaseDate: Date,
        isActive: Bool = true
    ) {
        self.transactionId = transactionId
        self.productId = productId
        self.contentHash = contentHash
        self.module = module
        self.userLocalId = userLocalId
        self.userId = userId
        self.purchasedAt = purchasedAt
        self.originalPurchaseDate = originalPurchaseDate
        self.isActive = isActive
    }
}
