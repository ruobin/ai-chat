//
//  MarkdownContent.swift
//  Parley
//
//  Parses assistant replies into renderable Markdown blocks.
//
//  Models emit Markdown into `Message.content` (headings, fenced code,
//  lists, tables), and we used to draw it with a bare `Text(_: String)`,
//  which renders the raw syntax literally. SwiftUI's `AttributedString`
//  Markdown support handles *inline* spans well but collapses block
//  structure — it has no concept of a code block's own background, a
//  list's hanging indent, or a table's columns. So block layout is scanned
//  here line-by-line and each block's inline text is then handed to
//  `AttributedString`, which stays consistent with the project's
//  no-third-party-dependencies posture.
//
//  Two constraints drive the odd-looking parts:
//
//  * Streaming. `StreamBuffer` flushes ~15×/sec, so this runs repeatedly on
//    a growing, usually *syntactically incomplete* string (an unclosed
//    fence, a half-typed `**bold`). Every construct therefore has to have a
//    defined unterminated form, and results are cached by content so
//    unrelated re-renders don't re-parse.
//  * Trust. `[source:N]` citations are resolved against the app-owned
//    source map *before* parsing, and links the model writes itself are
//    scheme-checked after. See `sourceLinks` and `sanitizeLinks`.
//

import Foundation
import SwiftUI

// MARK: - Block model

/// One renderable chunk of a reply. Inline emphasis lives inside the
/// `AttributedString` payloads; this only describes block layout.
enum MarkdownBlockKind {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case codeBlock(language: String?, code: String)
    case list(items: [MarkdownListItem])
    case quote(blocks: [MarkdownBlock])
    case table(MarkdownTable)
    case thematicBreak
}

/// A block plus its position in the reply. Identity is positional on
/// purpose: while streaming, the trailing block grows in place, and keying
/// `ForEach` by position (rather than by content) is what stops SwiftUI
/// tearing down and rebuilding every earlier block on each flush.
struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: MarkdownBlockKind
}

struct MarkdownListItem: Identifiable {
    let id: Int
    /// Indent level, 0 for a top-level item.
    let depth: Int
    /// Number to draw for an ordered item; `nil` renders a bullet.
    let ordinal: Int?
    /// Set for task-list items (`- [ ]` / `- [x]`), `nil` otherwise.
    let isChecked: Bool?
    let text: AttributedString
}

struct MarkdownTable {
    enum Alignment {
        case leading, center, trailing
    }
    let header: [AttributedString]
    let alignments: [Alignment]
    let rows: [[AttributedString]]
}

// MARK: - Parser

/// Main-actor isolated because of the memo table below: parsing is only ever
/// driven from SwiftUI view bodies, and this keeps the shared cache free of
/// data races without paying for a lock on every lookup.
@MainActor
enum MarkdownContent {
    /// Parses `source` into blocks, resolving `[source:N]` citations against
    /// `citations` (ID → URL). Results are memoised; see `cache`.
    static func parse(
        _ source: String,
        citations: [Int: URL] = [:]
    ) -> [MarkdownBlock] {
        let key = CacheKey(source: source, citations: citations)
        if let hit = cache[key] { return hit }
        let blocks = Self.blocks(in: source, citations: citations)
        store(blocks, for: key)
        return blocks
    }

    /// True when the text contains nothing worth block-rendering, letting
    /// callers keep a plain `Text` (cheaper, and preserves exact whitespace)
    /// for the overwhelmingly common short reply.
    static func isPlain(_ source: String) -> Bool {
        !source.contains(where: { "*_`#>|[~".contains($0) })
            && !source.contains("- ")
            && !source.contains("1. ")
    }

    // MARK: Block scanning

    private static func blocks(
        in source: String,
        citations: [Int: URL]
    ) -> [MarkdownBlock] {
        var kinds: [MarkdownBlockKind] = []
        let lines = source.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                // Unterminated fences are normal mid-stream: absorb the rest
                // of the text as code rather than dropping the block, so a
                // code block renders as code from its first line.
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence), fenceMarker(candidate) != nil {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                kinds.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            if isThematicBreak(trimmed) {
                kinds.append(.thematicBreak)
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                let text = trimmed.dropFirst(heading)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                kinds.append(.heading(
                    level: heading,
                    text: inline(text, citations: citations)
                ))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var stripped = Substring(candidate.dropFirst())
                    if stripped.hasPrefix(" ") { stripped = stripped.dropFirst() }
                    quoted.append(String(stripped))
                    index += 1
                }
                kinds.append(.quote(blocks: Self.blocks(
                    in: quoted.joined(separator: "\n"),
                    citations: citations
                )))
                continue
            }

            if index + 1 < lines.count,
               let table = parseTable(lines, from: &index, citations: citations) {
                kinds.append(.table(table))
                continue
            }

            if listMarker(line) != nil {
                var items: [MarkdownListItem] = []
                while index < lines.count, let marker = listMarker(lines[index]) {
                    items.append(MarkdownListItem(
                        id: items.count,
                        depth: min(marker.depth, 4),
                        ordinal: marker.ordinal,
                        isChecked: marker.isChecked,
                        text: inline(marker.text, citations: citations)
                    ))
                    index += 1
                }
                kinds.append(.list(items: items))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty
                    || fenceMarker(candidateTrimmed) != nil
                    || headingLevel(candidateTrimmed) != nil
                    || isThematicBreak(candidateTrimmed)
                    || candidateTrimmed.hasPrefix(">")
                    || listMarker(candidate) != nil {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            if !paragraph.isEmpty {
                kinds.append(.paragraph(inline(
                    paragraph.joined(separator: "\n"),
                    citations: citations
                )))
            }
        }

        return kinds.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    // MARK: Block recognisers

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return marker
        }
        return nil
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private struct ListMarker {
        let depth: Int
        let ordinal: Int?
        let isChecked: Bool?
        let text: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        // Tabs count as a full level; spaces as two per level, which matches
        // what models actually emit for nested lists.
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        var rest = Substring(line.dropFirst(indent.count))
        guard !rest.isEmpty else { return nil }

        var ordinal: Int?
        if let first = rest.first, "-*+".contains(first) {
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let afterDigits = rest.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
                return nil
            }
            ordinal = Int(digits)
            rest = afterDigits.dropFirst()
        }
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }

        var text = rest.trimmingCharacters(in: .whitespaces)
        var isChecked: Bool?
        for (token, state) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
        where text.hasPrefix(token) {
            isChecked = state
            text = String(text.dropFirst(token.count))
            break
        }
        return ListMarker(depth: depth, ordinal: ordinal, isChecked: isChecked, text: text)
    }

    /// Parses a GitHub-style pipe table. Only commits if the delimiter row
    /// is present, so a paragraph that merely contains a `|` isn't
    /// misread — and, mid-stream, a table stays a paragraph until its
    /// second line lands.
    private static func parseTable(
        _ lines: [String],
        from index: inout Int,
        citations: [Int: URL]
    ) -> MarkdownTable? {
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|") else { return nil }
        let delimiterLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard delimiterLine.contains("|"),
              delimiterLine.allSatisfy({ "|-: \t".contains($0) }),
              delimiterLine.contains("-")
        else { return nil }

        let header = splitRow(headerLine)
        let alignments = splitRow(delimiterLine).map { spec -> MarkdownTable.Alignment in
            let leading = spec.hasPrefix(":")
            let trailing = spec.hasSuffix(":")
            if leading && trailing { return .center }
            return trailing ? .trailing : .leading
        }
        guard !header.isEmpty else { return nil }

        index += 2
        var rows: [[AttributedString]] = []
        while index < lines.count {
            let row = lines[index].trimmingCharacters(in: .whitespaces)
            guard row.contains("|"), !row.isEmpty else { break }
            var cells = splitRow(row).map { inline($0, citations: citations) }
            // Pad or trim so every row matches the header's column count;
            // ragged rows are common in generated tables.
            while cells.count < header.count { cells.append(AttributedString()) }
            rows.append(Array(cells.prefix(header.count)))
            index += 1
        }

        var paddedAlignments = alignments
        while paddedAlignments.count < header.count { paddedAlignments.append(.leading) }
        return MarkdownTable(
            header: header.map { inline($0, citations: citations) },
            alignments: Array(paddedAlignments.prefix(header.count)),
            rows: rows
        )
    }

    private static func splitRow(_ line: String) -> [String] {
        var trimmed = Substring(line)
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Inline parsing

    /// Renders one block's inline Markdown, resolving citations first and
    /// scheme-checking whatever links survive.
    static func inline(_ source: String, citations: [Int: URL]) -> AttributedString {
        let prepared = sourceLinks(in: source, citations: citations)
        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: prepared,
                options: .init(
                    allowsExtendedAttributes: true,
                    // Block syntax is handled above; asking for inline only
                    // keeps hard/soft line breaks inside a paragraph intact.
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            // Malformed partial syntax mid-stream: show the raw text rather
            // than dropping the block.
            return AttributedString(source)
        }
        styleInlineCode(&attributed)
        sanitizeLinks(&attributed)
        return attributed
    }

    /// Rewrites `[source:N]` markers into Markdown links pointing at the
    /// URL the app itself retrieved. Unmatched IDs are escaped to literal
    /// text, so the model can't fabricate a citation to a page that was
    /// never fetched — the only URLs reachable this way are ones already
    /// validated by `WebResearchService`.
    private static func sourceLinks(in source: String, citations: [Int: URL]) -> String {
        guard source.contains("[source:") else { return source }
        var output = ""
        var remainder = Substring(source)
        while let start = remainder.range(of: "[source:") {
            output += remainder[..<start.lowerBound]
            let afterPrefix = remainder[start.upperBound...]
            guard let close = afterPrefix.firstIndex(of: "]") else {
                output += remainder[start.lowerBound...]
                return output
            }
            let digits = afterPrefix[..<close]
            if let id = Int(digits), let url = citations[id] {
                output += "[\(id)](\(url.absoluteString))"
            } else {
                output += "\\[source:\(digits)\\]"
            }
            remainder = afterPrefix[afterPrefix.index(after: close)...]
        }
        return output + remainder
    }

    /// SwiftUI renders emphasis and strikethrough from `inlinePresentationIntent`
    /// on its own, but leaves inline code visually identical to body text.
    private static func styleInlineCode(_ attributed: inout AttributedString) {
        let ranges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in ranges {
            attributed[range].font = .system(.body, design: .monospaced)
            attributed[range].foregroundColor = .pink
        }
    }

    /// Drops link attributes for anything that isn't plain web navigation.
    /// Model output is untrusted text, and `WEB_SEARCH_DESIGN.md` requires
    /// that a link the model wrote never gets the affordance of a verified
    /// citation — `javascript:`, `data:`, and `file:` must not be tappable
    /// at all. The text stays visible; only the tap target is removed.
    private static func sanitizeLinks(_ attributed: inout AttributedString) {
        let allowed: Set<String> = ["http", "https", "mailto"]
        let unsafe = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link else { return nil }
            let scheme = link.scheme?.lowercased() ?? ""
            return allowed.contains(scheme) ? nil : run.range
        }
        for range in unsafe {
            attributed[range].link = nil
            attributed[range].underlineStyle = nil
            attributed[range].foregroundColor = nil
        }
    }

    // MARK: Cache

    private struct CacheKey: Hashable {
        let source: String
        let citations: [Int: URL]
    }

    /// Bounded memo table. Streaming re-parses a growing string many times a
    /// second, and SwiftUI re-evaluates bodies for reasons unrelated to
    /// content, so without this a long reply is re-parsed constantly.
    private static var cache: [CacheKey: [MarkdownBlock]] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 48

    private static func store(_ blocks: [MarkdownBlock], for key: CacheKey) {
        cache[key] = blocks
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
