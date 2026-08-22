import Foundation

/// 从一段纯文本里认出「这是代码」以及「是哪门语言」。
///
/// **口径：认不出语言就不算代码。** 没有「无语言的代码」这种中间态 ——
/// 行内那个语言标签就是这个类型存在的全部意义，标不出来的话，
/// 一行代码和一行普通文本在列表里长得一模一样，多这个类型只是白多一次误判机会。
///
/// 这是启发式，一定会漏判。漏判的代价只是图标和颜色不同，所以整套规则偏保守 ——
/// **宁可把代码当成文本，也不要把一段中文标成 `perl`。**
///
/// 和「不做密码识别」是同一个理由的两面：那边是猜错会害人所以不猜，
/// 这边是猜错只是难看所以允许猜，但仍然只在证据充分时才开口。
enum CodeDetector {

    /// 认出来返回语言名（小写，直接进 `PerchItem.language`），认不出返回 nil。
    ///
    /// 调用方：`DropIngestor.ingestText`，**排在链接判定之后**。
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 太短的片段证据不够，`{}` 两个字符也能凑出「代码特征」。
        guard trimmed.count >= 12 else { return nil }

        // 只看开头 4000 个字符。再往后对判定没有增量帮助，
        // 而这段代码在**每一次复制**都会跑一遍，不能让它随内容长度线性变慢。
        let sample = String(trimmed.prefix(4000))

        // 中文占比高的一律不当代码。带中文注释的代码依然能过 ——
        // 门槛是三成，注释占三成以上的代码片段本来就更像文档。
        guard !isMostlyCJK(sample) else { return nil }

        // 有明确外形的几种先认，它们不需要走打分。
        if let structured = detectStructured(sample, whole: trimmed) { return structured }

        var best: (language: String, score: Int)?
        for signature in signatures {
            guard let score = signature.score(in: sample) else { continue }
            if best == nil || score > best!.score {
                best = (signature.language, score)
            }
        }
        return best?.language
    }

    /// 语言 → 文件扩展名，拖出成真文件时用（`.swift` / `.py` / `.json`）。
    ///
    /// 认不出来返回 nil，调用方退回 `.txt` —— 内容一个字节都不会差，
    /// 只是拖到编辑器里少了高亮。
    static func fileExtension(for language: String?) -> String? {
        switch language {
        case "swift": "swift"
        case "python": "py"
        case "typescript": "ts"
        case "javascript": "js"
        case "java": "java"
        case "go": "go"
        case "rust": "rs"
        case "c": "c"
        case "sql": "sql"
        case "bash": "sh"
        case "css": "css"
        case "ruby": "rb"
        case "json": "json"
        case "xml": "xml"
        case "html": "html"
        case "php": "php"
        default: nil
        }
    }

    // MARK: - 外形明确的几种

    /// JSON / XML / HTML / PHP / shebang。
    ///
    /// 这几种有唯一且不会误伤的外形特征，走打分反而绕远。
    private static func detectStructured(_ sample: String, whole: String) -> String? {
        // JSON 用真解析器判，不用特征词。`{` 开头 `}` 结尾但解析不过的，
        // 多半是 Swift/JS 的代码块，交给下面的打分去认。
        if let first = sample.first, first == "{" || first == "[",
           let data = whole.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "json"
        }

        if sample.hasPrefix("<?xml") { return "xml" }
        if sample.hasPrefix("<?php") || sample.contains("<?php") { return "php" }

        let lowered = sample.lowercased()
        if lowered.hasPrefix("<!doctype html") || lowered.contains("<html") || lowered.contains("</div>") {
            return "html"
        }

        // shebang 直接写着用什么解释器跑，比任何特征词都可靠。
        if sample.hasPrefix("#!") {
            let firstLine = sample.prefix(while: { $0 != "\n" }).lowercased()
            if firstLine.contains("python") { return "python" }
            if firstLine.contains("node") { return "javascript" }
            if firstLine.contains("ruby") { return "ruby" }
            if firstLine.contains("bash") || firstLine.contains("/sh") || firstLine.contains("zsh") {
                return "bash"
            }
        }

        return nil
    }

    // MARK: - 打分

    private struct Signature {

        /// 命中一条**强特征**（3 分）就够，全靠**弱特征**则要凑够三条。
        static let threshold = 3

        let language: String

        /// 强特征：在普通中英文段落里几乎不会出现的字符串。
        let strong: [String]

        /// 弱特征：单独出现说明不了什么，凑够数量才算数。
        let weak: [String]

        /// 达不到门槛返回 nil。
        func score(in sample: String) -> Int? {
            let strongHits = strong.filter { sample.contains($0) }.count
            let weakHits = weak.filter { sample.contains($0) }.count
            let total = strongHits * 3 + weakHits
            guard total >= Self.threshold else { return nil }

            // 🚨 全靠弱特征凑出来的分数不算数，除非这段文本整体就长得像代码。
            // 「Please let me know」能刷到 Swift 的两三个弱特征，
            // 但它没有括号、没有缩进、没有分号 —— 这道闸就是拦它的。
            if strongHits == 0 && !looksLikeCode(sample) { return nil }

            return total
        }
    }

    /// 顺序即优先级：分数相同时排在前面的赢。
    ///
    /// TypeScript 放在 JavaScript 前面 —— 两者弱特征几乎全重合，
    /// 只有 TS 独有的类型语法能把它们分开，让 TS 先判才有机会命中。
    private static let signatures: [Signature] = [
        Signature(
            language: "swift",
            strong: [
                "import SwiftUI", "import Foundation", "import AppKit", "import UIKit",
                "@MainActor", "@State", "@Published", "@escaping",
                "-> some View", "guard let ", "if let ", "func ",
            ],
            weak: ["let ", "var ", "struct ", "enum ", "extension ", "?? ", "Self.", ".shared", "nil"]
        ),
        Signature(
            language: "python",
            strong: [
                "if __name__", "__init__", "elif ", "def ", "lambda ",
                "import numpy", "import pandas", "print(f\"",
            ],
            weak: ["self.", "import ", "from ", "None", "True", "False", "return ", "):"]
        ),
        Signature(
            language: "typescript",
            strong: [
                "interface ", ": string", ": number", ": boolean",
                "as const", "readonly ", "export type ", "<T>",
            ],
            weak: ["const ", "export ", "import ", "=>", "return ", "null"]
        ),
        Signature(
            language: "javascript",
            strong: [
                "console.log(", "document.querySelector", "export default",
                "async function", "=> {", "require(", "addEventListener(",
            ],
            weak: ["const ", "let ", "function ", "return ", "=>", "null", "undefined", "await "]
        ),
        Signature(
            language: "java",
            strong: ["public static void main", "System.out.println", "public class ", "@Override"],
            weak: ["private ", "public ", "new ", "void ", "extends ", "implements ", ";"]
        ),
        Signature(
            language: "go",
            strong: ["package main", "func main()", "fmt.Print", "err != nil", ":= range"],
            weak: [":= ", "func ", "defer ", "chan ", "go func", "nil"]
        ),
        Signature(
            language: "rust",
            strong: ["fn main()", "let mut ", "println!", "use std::", "-> Result<", "impl "],
            weak: ["fn ", "match ", "&str", "Vec<", "Some(", "None", "unwrap()"]
        ),
        Signature(
            language: "c",
            strong: ["#include <", "int main(", "printf(", "malloc(", "std::"],
            weak: ["void ", "return ", "struct ", "char ", "sizeof", ";"]
        ),
        Signature(
            // SQL 的强特征**只认大写**。小写的 select / from / where
            // 在英文散文里太常见了（"select the file from the list"），
            // 只能放进弱特征，靠 looksLikeCode 那道闸兜着。
            language: "sql",
            strong: [
                "SELECT ", "INSERT INTO", "CREATE TABLE", "DELETE FROM",
                "ALTER TABLE", "LEFT JOIN", "GROUP BY", "ORDER BY",
            ],
            weak: ["select ", " from ", " where ", " join ", " on ", " limit ", ";"]
        ),
        Signature(
            language: "bash",
            strong: [
                "#!/bin/", "#!/usr/bin/env", "brew install", "npm install", "npm run",
                "git clone", "git commit", "chmod +x", "sudo ", "apt-get ",
            ],
            weak: ["$(", "echo ", "export ", "&& ", "| grep", "rm -", "cd ", "-rf"]
        ),
        Signature(
            language: "css",
            strong: ["@media ", "!important", "-webkit-", "rgba(", "px;", "@keyframes"],
            weak: ["color:", "background:", "margin:", "padding:", "display:", "flex", "}"]
        ),
        Signature(
            language: "ruby",
            strong: ["attr_accessor", "require '", "do |", "puts ", "\nend"],
            weak: ["def ", "nil", "=> ", "@", "elsif"]
        ),
    ]

    // MARK: - 两道闸

    /// 中文（含日文汉字）占非空白字符的比例超过三成就不当代码。
    private static func isMostlyCJK(_ sample: String) -> Bool {
        var cjk = 0
        var total = 0
        for scalar in sample.unicodeScalars {
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            total += 1
            // CJK 统一表意文字基本区 + 扩展 A，够用；不追求覆盖全部扩展区。
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                cjk += 1
            }
        }
        guard total > 0 else { return false }
        return Double(cjk) / Double(total) > 0.3
    }

    /// 「这段文本整体像不像代码」，与语言无关。
    ///
    /// 只在**没有任何强特征**时才会被问到 —— 强特征本身已经足够定性了。
    /// 四条信号里满足两条即可。
    private static func looksLikeCode(_ sample: String) -> Bool {
        var signals = 0

        // ① 标点密度。代码里 `(){}[];=<>` 成堆，散文里零星。
        let punctuation: Set<Character> = ["{", "}", "(", ")", "[", "]", ";", "=", "<", ">"]
        if sample.filter({ punctuation.contains($0) }).count >= 3 { signals += 1 }

        // ② 运算符/路径符号。这些序列在自然语言里基本不出现。
        let operators = ["()", "=>", "->", "::", ":=", "==", "!=", "&&", "||", "+=", "</"]
        if operators.contains(where: { sample.contains($0) }) { signals += 1 }

        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)

        // ③ 有缩进行。多行文本里出现前导空白，基本只有代码和 YAML 会这样。
        if lines.contains(where: { $0.hasPrefix("  ") || $0.hasPrefix("\t") }) { signals += 1 }

        // ④ 注释行或以分号/花括号收尾的行。
        if lines.contains(where: { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            return text.hasPrefix("//") || text.hasPrefix("/*") || text.hasPrefix("#")
                || text.hasSuffix(";") || text.hasSuffix("{") || text.hasSuffix("}")
        }) { signals += 1 }

        return signals >= 2
    }
}
