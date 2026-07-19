import Foundation
import SwiftUI

/// LLM 返回的 markdown 文本预处理(三模块 AI 解读共用:深度解析 / 合盘 / 每日运势)。
///
/// 背景:后端 prompt 模板大量用 `**粗体**` / 编号列表(`prompts.py`),LLM
/// 自然返回带 `# 标题` / `- 列表` / `> 引用` / ```` ``` 代码块 ```` 的 markdown。
/// SwiftUI `Text` 只渲染 inline markdown(粗体/斜体/代码/链接),block-level
/// 标记会原样显示成字面 `####`,UX 差。
///
/// 策略:
/// - **strip block 标记**:标题 / 无序+有序列表 / 引用 / 代码围栏(单独成行)
/// - **保留 inline 标记**:`**粗体**` `*斜体*` `` `代码` ``,交给
///   `AttributedString(markdown:)` 渲染
/// - **fallback**:`AttributedString(markdown:)` 失败 → 粗暴 inline 也 strip + verbatim
///   (避免渲染失败时字面 `**` 出现在 UI)
///
/// 不引入第三方 markdown 库(违反"不擅自加依赖")。SwiftUI Text 不支持
/// 完整 block 渲染,strip block 是务实权衡。
enum MarkdownSanitizer {

    /// atx 标题前缀:`#` ~ `######` + 至少一个空白。
    private static let atxHeader = try! Regex(#"^#{1,6}\s+"#)
    /// 无序列表标记:`-` / `*` / `+` + 空白。
    private static let bulletList = try! Regex(#"^[-*+]\s+"#)
    /// 有序列表标记:数字 + `.` + 空白。
    private static let numberedList = try! Regex(#"^\d+\.\s+"#)
    /// 引用标记:1+ 个 `>` + 可选空白。
    private static let blockquote = try! Regex(#"^>+\s*"#)
    /// 代码围栏行:整行匹配 ``` (可带语言标识 like ```python)。
    private static let codeFenceLine = try! Regex(#"^\s*```[^\n]*$"#)

    /// 把原始 markdown 转为 AttributedString,可直传 `Text(_)`。
    ///
    /// 步骤:
    /// 1. strip block 标记(行级处理)
    /// 2. 尝试 `AttributedString(markdown:)` 渲染 inline
    /// 3. 失败 fallback 到 inline strip + verbatim
    static func rendered(_ raw: String) -> AttributedString {
        let cleaned = stripBlockMarkers(raw)
        if let attr = try? AttributedString(markdown: cleaned) {
            return attr
        }
        return AttributedString(stripInlineMarkers(cleaned))
    }

    // MARK: - Private

    /// 行级处理:去掉每行开头的 block 标记。
    private static func stripBlockMarkers(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map(stripLine)
            .joined(separator: "\n")
    }

    private static func stripLine(_ line: String) -> String {
        // 代码围栏整行替换为空(避免代码块边界残留 ```)
        if line.wholeMatch(of: codeFenceLine) != nil {
            return ""
        }
        return line
            .replacing(atxHeader, with: "")
            .replacing(bulletList, with: "")
            .replacing(numberedList, with: "")
            .replacing(blockquote, with: "")
    }

    /// inline 标记粗暴 strip(只在 `AttributedString(markdown:)` 失败时兜底)。
    private static func stripInlineMarkers(_ raw: String) -> String {
        raw.replacingOccurrences(of: "**", with: "")
           .replacingOccurrences(of: "*", with: "")
           .replacingOccurrences(of: "`", with: "")
    }
}
