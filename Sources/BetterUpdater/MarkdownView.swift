//
//  MarkdownView.swift
//  \(BetterUpdater.configuration.displayName)
//
//  Reusable GitHub Flavored Markdown renderer (Pure SwiftUI).
//

import SwiftUI

// MARK: - Markdown View

struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var i = 0
        var currentListItems: [String] = []
        var currentBlockquote: [String] = []
        var inCodeBlock = false
        var codeBlockContent: [String] = []
        var codeBlockLanguage: String = ""

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.codeBlock(language: codeBlockLanguage, code: codeBlockContent.joined(separator: "\n")))
                    codeBlockContent = []
                    codeBlockLanguage = ""
                    inCodeBlock = false
                } else {
                    if !currentListItems.isEmpty {
                        blocks.append(.unorderedList(items: currentListItems))
                        currentListItems = []
                    }
                    if !currentBlockquote.isEmpty {
                        blocks.append(.blockquote(text: currentBlockquote.joined(separator: " ")))
                        currentBlockquote = []
                    }
                    inCodeBlock = true
                    codeBlockLanguage = String(trimmed.dropFirst(3))
                }
                i += 1
                continue
            }

            if inCodeBlock {
                codeBlockContent.append(line)
                i += 1
                continue
            }

            if trimmed.isEmpty {
                if !currentListItems.isEmpty {
                    blocks.append(.unorderedList(items: currentListItems))
                    currentListItems = []
                }
                if !currentBlockquote.isEmpty {
                    blocks.append(.blockquote(text: currentBlockquote.joined(separator: " ")))
                    currentBlockquote = []
                }
                i += 1
                continue
            }

            if let imgMatch = parseImgTag(trimmed) {
                blocks.append(.image(alt: imgMatch.alt, url: imgMatch.src, width: imgMatch.width, height: imgMatch.height))
                i += 1
                continue
            }

            if let mdImgMatch = parseMarkdownImage(trimmed) {
                blocks.append(.image(alt: mdImgMatch.alt, url: mdImgMatch.url, width: nil, height: nil))
                i += 1
                continue
            }

            if trimmed.hasPrefix("######") {
                blocks.append(.header(level: 6, text: String(trimmed.dropFirst(7))))
            } else if trimmed.hasPrefix("#####") {
                blocks.append(.header(level: 5, text: String(trimmed.dropFirst(6))))
            } else if trimmed.hasPrefix("####") {
                blocks.append(.header(level: 4, text: String(trimmed.dropFirst(5))))
            } else if trimmed.hasPrefix("###") {
                blocks.append(.header(level: 3, text: String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("##") {
                blocks.append(.header(level: 2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.header(level: 1, text: String(trimmed.dropFirst(2))))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
            } else if trimmed.hasPrefix("> ") {
                currentBlockquote.append(String(trimmed.dropFirst(2)))
                i += 1
                continue
            } else if trimmed.hasPrefix("- [ ] ") {
                currentListItems.append("☐ " + String(trimmed.dropFirst(6)))
                i += 1
                continue
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                currentListItems.append("☑ " + String(trimmed.dropFirst(6)))
                i += 1
                continue
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !currentBlockquote.isEmpty {
                    blocks.append(.blockquote(text: currentBlockquote.joined(separator: " ")))
                    currentBlockquote = []
                }
                currentListItems.append(String(trimmed.dropFirst(2)))
                i += 1
                continue
            } else if trimmed.range(of: "^\\d+\\. ", options: .regularExpression) != nil {
                if !currentBlockquote.isEmpty {
                    blocks.append(.blockquote(text: currentBlockquote.joined(separator: " ")))
                    currentBlockquote = []
                }
                if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression) {
                    currentListItems.append(String(trimmed[match.upperBound...]))
                }
                i += 1
                continue
            } else {
                if !currentListItems.isEmpty {
                    blocks.append(.unorderedList(items: currentListItems))
                    currentListItems = []
                }
                if !currentBlockquote.isEmpty {
                    blocks.append(.blockquote(text: currentBlockquote.joined(separator: " ")))
                    currentBlockquote = []
                }
                blocks.append(.paragraph(text: trimmed))
            }

            i += 1
        }

        if !currentListItems.isEmpty {
            blocks.append(.unorderedList(items: currentListItems))
        }
        if !currentBlockquote.isEmpty {
            blocks.append(.blockquote(text: currentBlockquote.joined(separator: " ")))
        }
        if inCodeBlock && !codeBlockContent.isEmpty {
            blocks.append(.codeBlock(language: codeBlockLanguage, code: codeBlockContent.joined(separator: "\n")))
        }

        return blocks
    }

    // MARK: - Image Tag Parsers

    private func parseImgTag(_ line: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?)? {
        guard line.range(of: "<img\\s", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let srcPattern = "src\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let srcRegex = try? NSRegularExpression(pattern: srcPattern, options: .caseInsensitive),
              let srcMatch = srcRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let srcRange = Range(srcMatch.range(at: 1), in: line) else {
            return nil
        }
        var alt = ""
        let altPattern = "alt\\s*=\\s*[\"']([^\"']*)[\"']"
        if let altRegex = try? NSRegularExpression(pattern: altPattern, options: .caseInsensitive),
           let altMatch = altRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let altRange = Range(altMatch.range(at: 1), in: line) {
            alt = String(line[altRange])
        }

        let width = Self.parseNumericAttribute("width", in: line)
        let height = Self.parseNumericAttribute("height", in: line)

        return (src: String(line[srcRange]), alt: alt, width: width, height: height)
    }

    private func parseMarkdownImage(_ line: String) -> (alt: String, url: String)? {
        let pattern = "^!\\[([^\\]]*)\\]\\(([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let altRange = Range(match.range(at: 1), in: line),
              let urlRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return (alt: String(line[altRange]), url: String(line[urlRange]))
    }

    private static func parseNumericAttribute(_ name: String, in line: String) -> CGFloat? {
        let pattern = "\(name)\\s*=\\s*[\"']?(\\d+(?:\\.\\d+)?)[\"']?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let valRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valRange]) else {
            return nil
        }
        return CGFloat(value)
    }
}

// MARK: - Block Types

enum MarkdownBlock {
    case header(level: Int, text: String)
    case paragraph(text: String)
    case unorderedList(items: [String])
    case codeBlock(language: String, code: String)
    case blockquote(text: String)
    case horizontalRule
    case image(alt: String, url: String, width: CGFloat?, height: CGFloat?)
}

// MARK: - Block View

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .header(let level, let text):
            headerView(level: level, text: text)

        case .paragraph(let text):
            Text(parseInlineMarkdown(text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        if item.hasPrefix("☐ ") || item.hasPrefix("☑ ") {
                            Text(String(item.prefix(1)))
                                .font(.system(size: 13))
                            Text(parseInlineMarkdown(String(item.dropFirst(2))))
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("•")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(parseInlineMarkdown(item))
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )

        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)

                Text(parseInlineMarkdown(text))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)

        case .image(let alt, let urlString, let width, let height):
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: width ?? .infinity,
                                maxHeight: height
                            )
                            .cornerRadius(8)
                    case .failure:
                        if !alt.isEmpty {
                            Text(alt)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    default:
                        ProgressView()
                            .frame(height: 60)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headerView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: 8) {
                Text(parseInlineMarkdown(text))
                    .font(.system(size: 20, weight: .bold))
                Divider()
            }
        case 2:
            Text(parseInlineMarkdown(text))
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 4)
        case 3:
            Text(parseInlineMarkdown(text))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
        default:
            Text(parseInlineMarkdown(text))
                .font(.system(size: 13, weight: .semibold))
        }
    }

    // MARK: - Inline Markdown Parser

    func parseInlineMarkdown(_ text: String) -> AttributedString {
        var result = text

        var codeSpans: [String] = []
        // Match any number of backticks so `cmd` and ``cmd + ` `` (literal
        // backtick inside) both parse as one code span.
        let codePattern = "(`+)((?:(?!\\1).)+?)\\1"
        if let regex = try? NSRegularExpression(pattern: codePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()
            for match in matches {
                if let codeRange = Range(match.range(at: 2), in: result),
                   let fullRange = Range(match.range, in: result) {
                    var code = String(result[codeRange])
                    if code.count >= 2,
                       code.first == " ", code.last == " ",
                       code.contains(where: { !$0.isWhitespace }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    codeSpans.append(code)
                    result.replaceSubrange(fullRange, with: "§CODE\(codeSpans.count - 1)§")
                }
            }
        }

        var links: [(text: String, url: String)] = []
        let linkPattern = "\\[([^\\]]+)\\]\\(([^)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()
            for match in matches {
                if let textRange = Range(match.range(at: 1), in: result),
                   let urlRange = Range(match.range(at: 2), in: result),
                   let fullRange = Range(match.range, in: result) {
                    let linkText = String(result[textRange])
                    let linkUrl = String(result[urlRange])
                    links.append((text: linkText, url: linkUrl))
                    result.replaceSubrange(fullRange, with: "§LINK\(links.count - 1)§")
                }
            }
        }

        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "§BOLD§$1§/BOLD§", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "§BOLD§$1§/BOLD§", options: .regularExpression)

        result = result.replacingOccurrences(of: "(?<![§])\\*([^*]+)\\*(?![§])", with: "§ITALIC§$1§/ITALIC§", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![§])_([^_]+)_(?![§])", with: "§ITALIC§$1§/ITALIC§", options: .regularExpression)

        result = result.replacingOccurrences(of: "~~(.+?)~~", with: "§STRIKE§$1§/STRIKE§", options: .regularExpression)

        var attributed = AttributedString()
        var current = result

        while !current.isEmpty {
            if let boldStart = current.range(of: "§BOLD§") {
                let before = String(current[..<boldStart.lowerBound])
                attributed.append(processPlainText(before, codeSpans: codeSpans, links: links))
                current = String(current[boldStart.upperBound...])

                if let boldEnd = current.range(of: "§/BOLD§") {
                    var boldContent = AttributedString(String(current[..<boldEnd.lowerBound]))
                    boldContent.font = .system(size: 13, weight: .semibold)
                    attributed.append(boldContent)
                    current = String(current[boldEnd.upperBound...])
                }
            } else if let italicStart = current.range(of: "§ITALIC§") {
                let before = String(current[..<italicStart.lowerBound])
                attributed.append(processPlainText(before, codeSpans: codeSpans, links: links))
                current = String(current[italicStart.upperBound...])

                if let italicEnd = current.range(of: "§/ITALIC§") {
                    var italicContent = AttributedString(String(current[..<italicEnd.lowerBound]))
                    italicContent.font = .system(size: 13).italic()
                    attributed.append(italicContent)
                    current = String(current[italicEnd.upperBound...])
                }
            } else if let strikeStart = current.range(of: "§STRIKE§") {
                let before = String(current[..<strikeStart.lowerBound])
                attributed.append(processPlainText(before, codeSpans: codeSpans, links: links))
                current = String(current[strikeStart.upperBound...])

                if let strikeEnd = current.range(of: "§/STRIKE§") {
                    var strikeContent = AttributedString(String(current[..<strikeEnd.lowerBound]))
                    strikeContent.strikethroughStyle = .single
                    attributed.append(strikeContent)
                    current = String(current[strikeEnd.upperBound...])
                }
            } else {
                attributed.append(processPlainText(current, codeSpans: codeSpans, links: links))
                break
            }
        }

        return attributed
    }

    private func processPlainText(_ text: String, codeSpans: [String], links: [(text: String, url: String)]) -> AttributedString {
        var result = AttributedString()
        var current = text

        while !current.isEmpty {
            if let codeMatch = current.range(of: "§CODE(\\d+)§", options: .regularExpression) {
                let before = String(current[..<codeMatch.lowerBound])
                result.append(AttributedString(before))

                let matchStr = String(current[codeMatch])
                if let indexMatch = matchStr.range(of: "\\d+", options: .regularExpression),
                   let index = Int(matchStr[indexMatch]),
                   index < codeSpans.count {
                    var codeAttr = AttributedString(codeSpans[index])
                    codeAttr.font = .system(size: 12, design: .monospaced)
                    codeAttr.backgroundColor = Color.secondary.opacity(0.15)
                    result.append(codeAttr)
                }

                current = String(current[codeMatch.upperBound...])
            } else if let linkMatch = current.range(of: "§LINK(\\d+)§", options: .regularExpression) {
                let before = String(current[..<linkMatch.lowerBound])
                result.append(AttributedString(before))

                let matchStr = String(current[linkMatch])
                if let indexMatch = matchStr.range(of: "\\d+", options: .regularExpression),
                   let index = Int(matchStr[indexMatch]),
                   index < links.count {
                    var linkAttr = AttributedString(links[index].text)
                    linkAttr.foregroundColor = .accentColor
                    if let url = URL(string: links[index].url) {
                        linkAttr.link = url
                    }
                    result.append(linkAttr)
                }

                current = String(current[linkMatch.upperBound...])
            } else {
                result.append(AttributedString(current))
                break
            }
        }

        return result
    }
}
