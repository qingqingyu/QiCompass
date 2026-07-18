import Foundation

// MARK: - Request

/// POST /api/entitlement/redeem 请求。对齐 backend/app/models/entitlement.py:EntitlementRedeemRequest
///
/// iOS StoreKit2 完成购买 → 拿到 transactionId → 调此接口写后端 entitlement 表。
struct EntitlementRedeemRequest: Codable, Sendable {
    let transactionId: String
    let productId: String
    let contentHash: String
    let module: String  // 基础名(bazi_deep / compatibility),不含 _free/_paid
    let userLocalId: String

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case productId = "product_id"
        case contentHash = "content_hash"
        case module
        case userLocalId = "user_local_id"
    }
}

// MARK: - Response

/// POST /api/entitlement/redeem 响应。对齐 backend EntitlementRedeemResponse
///
/// 后端 `entitled: Literal[True]`(永远 True,失败走错误响应),iOS 解为 Bool 兼容。
struct EntitlementRedeemResponse: Codable, Sendable {
    let entitled: Bool
    let transactionId: String
    let purchasedAt: Date
    let originalPurchaseDate: Date

    enum CodingKeys: String, CodingKey {
        case entitled
        case transactionId = "transaction_id"
        case purchasedAt = "purchased_at"
        case originalPurchaseDate = "original_purchase_date"
    }
}

// MARK: - Apple SKU 常量

/// Apple 商品 SKU(对齐 MONETIZATION.md §商品 SKU 列表)。
/// 客户端用这个跟 iOS StoreKit2 Product.products() 拿到的 product.id 对齐。
enum AppleProductID {
    /// 深度解析单次解锁(M3 启用)
    static let deepAnalysisSingle = "com.qicompass.deep_analysis.single"
    /// 合盘单次解锁(M4 启用)
    static let compatibilitySingle = "com.qicompass.compatibility.single"
}

/// Entitlement 表的 module 字段值(基础名,不含 _free/_paid)。
enum EntitlementModule {
    static let baziDeep = "bazi_deep"
    static let compatibility = "compatibility"
}
