//
//  MarkdownText.swift
//  Parley
//
//  Draws the blocks produced by `MarkdownContent` inside a chat bubble.
//
//  Layout notes that aren't obvious from the code:
//
//  * Everything is sized relative to the bubble's inherited `.body` font, so
//    Dynamic Type keeps working — headings scale with the user's text size
//    instead of being pinned to fixed point sizes.
//  * `MessageBubble` and `StreamingBubble` both render through
//    `MessageContentView`, so in-flight text and the committed message look
//    identical and there's no reformat flash when a stream lands.
//  * User bubbles deliberately opt out of Markdown: they show exactly what
//    was typed. Nobody wants their own `*asterisks*` silently eaten.
//

import SwiftUI

/// The text of one message bubble. Assistant replies get Markdown block
/// rendering; user text is shown verbatim.
struct MessageContentView: View {
    let content: String
    let role: MessageRole
    var citations: [Int: URL] = [:]

    var body: some View {
        if role == .user || MarkdownContent.isPlain(content) {
            Text(content)
                .textSelection(.enabled)
        } else {
            MarkdownText(content: content, citations: citations)
        }
    }
}

struct MarkdownText: View {
    let content: String
    var citations: [Int: URL] = [:]

    var body: some View {
        MarkdownBlockList(blocks: MarkdownContent.parse(content, citations: citations))
    }
}

private struct MarkdownBlockList: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block.kind)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlockKind

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(text)
                .font(.system(headingStyle(level), weight: level <= 2 ? .bold : .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // Headings that open a section need air above them, but not
                // when they're the very first block in a reply.
                .padding(.top, 2)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .list(let items):
            MarkdownListView(items: items)

        case .quote(let blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                MarkdownBlockList(blocks: blocks)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let table):
            MarkdownTableView(table: table)

        case .thematicBreak:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item)
                        // A fixed marker column keeps multi-line item text
                        // aligned under itself rather than wrapping back
                        // beneath the bullet.
                        .frame(minWidth: item.ordinal == nil ? 10 : 18, alignment: .trailing)
                    Text(item.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * 16)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem) -> some View {
        if let isChecked = item.isChecked {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.caption)
                .foregroundStyle(isChecked ? Color.accentColor : .secondary)
        } else if let ordinal = item.ordinal {
            Text("\(ordinal).")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            // Nested levels alternate the glyph, the way Markdown renderers
            // conventionally do, so depth is readable without indentation
            // alone carrying the meaning.
            Text(item.depth % 2 == 0 ? "•" : "◦")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Code blocks

private struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language.lowercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                    }
                } label: {
                    Label(
                        didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.5)

            // Code is the one place we don't wrap: breaking a long line
            // changes how it reads. Scroll horizontally instead, which also
            // keeps the bubble from being stretched by one long line.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        // Tables are the widest thing a model emits and the least willing to
        // wrap, so this scrolls horizontally rather than compressing columns
        // into unreadable slivers.
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    Divider().opacity(0.4)
                    row(cells, isHeader: false)
                        .background(
                            index.isMultiple(of: 2)
                                ? Color.clear
                                : Color.primary.opacity(0.03)
                        )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
    }

    private func row(_ cells: [AttributedString], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    Divider().opacity(0.4)
                }
                Text(cell)
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .textSelection(.enabled)
                    .frame(
                        minWidth: 64,
                        maxWidth: 240,
                        alignment: alignment(at: index)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(isHeader ? Color.primary.opacity(0.05) : Color.clear)
    }

    private func alignment(at index: Int) -> Alignment {
        guard index < table.alignments.count else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
