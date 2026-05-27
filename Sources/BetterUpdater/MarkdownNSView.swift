//
//  MarkdownNSView.swift
//  \(BetterUpdater.configuration.displayName)
//
//  Pure AppKit markdown renderer. Renders into an NSTextView using
//  NSAttributedString. Reuses the same MarkdownBlock parsing logic
//  from MarkdownView.swift.
//

import AppKit

enum MarkdownImageCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.name = "\(BetterUpdater.configuration.displayName).MarkdownImageCache"
        return cache
    }()

    static func clearAll() {
        shared.removeAllObjects()
    }
}

private final class WeakTextAttachmentBox: @unchecked Sendable {
    weak var attachment: NSTextAttachment?

    init(_ attachment: NSTextAttachment?) {
        self.attachment = attachment
    }
}

/// Pure AppKit `NSTextView` subclass that renders GitHub Flavored Markdown
/// as a selectable attributed string.
final class MarkdownNSView: NSTextView {

    nonisolated static let issueRepoSlug = "rokartur/\(BetterUpdater.configuration.displayName)"

    var markdown: String = "" {
        didSet { render() }
    }

    private var pendingAttachments: [(attachment: NSTextAttachment, url: URL, explicitWidth: CGFloat?, explicitHeight: CGFloat?)] = []

    private var lastLayoutWidth: CGFloat = 0

    override var isOpaque: Bool { false }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        relayoutIfWidthChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayoutIfWidthChanged()
    }

    private func relayoutIfWidthChanged() {
        let width = bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        render()
    }

    convenience init() {
        self.init(frame: .zero)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        isAutomaticLinkDetectionEnabled = true
    }

    // MARK: - Rendering

    private func render() {
        guard let textStorage = textStorage else { return }

        let blocks = parseBlocks(markdown)
        let result = NSMutableAttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                let spacing = NSMutableAttributedString(string: "\n\n")
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.paragraphSpacing = 2
                spacing.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: spacing.length))
                spacing.addAttribute(.font, value: NSFont.systemFont(ofSize: 4), range: NSRange(location: 0, length: spacing.length))
                result.append(spacing)
            }
            result.append(renderBlock(block))
        }

        textStorage.setAttributedString(result)

        if let container = textContainer, let layoutManager = layoutManager {
            layoutManager.ensureLayout(for: container)
            let usedRect = layoutManager.usedRect(for: container)
            let insetHeight = textContainerInset.height * 2
            let newHeight = ceil(usedRect.height + insetHeight)
            if newHeight > 0 {
                var frame = self.frame
                frame.size.height = newHeight
                self.frame = frame
            }
        }
        needsDisplay = true

        loadPendingImages()
    }

    // MARK: - Block Rendering

    private func renderBlock(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .header(let level, let text):
            return renderHeader(level: level, text: text)

        case .paragraph(let text):
            return parseInline(text, baseFont: .systemFont(ofSize: 13))

        case .unorderedList(let items):
            return renderList(items: items)

        case .codeBlock(_, let code):
            return renderCodeBlock(code: code)

        case .blockquote(let text):
            return renderBlockquote(text: text)

        case .horizontalRule:
            return renderHorizontalRule()

        case .image(let alt, let urlString, let width, let height):
            return renderImage(alt: alt, urlString: urlString, explicitWidth: width, explicitHeight: height)
        }
    }

    private func renderHeader(level: Int, text: String) -> NSAttributedString {
        let fontSize: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1: fontSize = 20; weight = .bold
        case 2: fontSize = 16; weight = .semibold
        case 3: fontSize = 14; weight = .semibold
        default: fontSize = 13; weight = .semibold
        }

        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let result = NSMutableAttributedString(attributedString: parseInline(text, baseFont: font))

        if level == 1 {
            let divider = NSAttributedString(
                string: "\n─────────────────────────────────────────",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 4),
                    .foregroundColor: NSColor.separatorColor,
                ]
            )
            result.append(divider)
        }

        return result
    }

    private func renderList(items: [String]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13)

        // Hanging indent so wrapped lines align with the text after the bullet
        // (matches how <ul><li> wraps in a browser), not the leading margin.
        let bulletIndent: CGFloat = 18
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 4
        para.headIndent = bulletIndent
        para.tabStops = [NSTextTab(textAlignment: .left, location: bulletIndent, options: [:])]
        para.defaultTabInterval = bulletIndent
        para.lineBreakMode = .byWordWrapping
        para.paragraphSpacing = 2

        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let line = NSMutableAttributedString()
            let bulletGlyph: String
            let bulletColor: NSColor
            let body: String
            if item.hasPrefix("☐ ") || item.hasPrefix("☑ ") {
                bulletGlyph = String(item.prefix(1))
                bulletColor = .labelColor
                body = String(item.dropFirst(2))
            } else {
                bulletGlyph = "•"
                bulletColor = .secondaryLabelColor
                body = item
            }

            line.append(NSAttributedString(string: bulletGlyph + "\t", attributes: [
                .font: baseFont,
                .foregroundColor: bulletColor,
                .paragraphStyle: para,
            ]))
            let inline = NSMutableAttributedString(attributedString: parseInline(body, baseFont: baseFont))
            inline.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: inline.length))
            line.append(inline)
            result.append(line)
        }

        return result
    }

    private func renderCodeBlock(code: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.headIndent = 12
        paraStyle.firstLineHeadIndent = 12
        paraStyle.tailIndent = -12

        return NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paraStyle,
            .backgroundColor: NSColor.controlBackgroundColor,
        ])
    }

    private func renderBlockquote(text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "│ ", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.4),
        ]))
        let inline = NSMutableAttributedString(attributedString: parseInline(text, baseFont: .systemFont(ofSize: 13)))
        inline.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                            range: NSRange(location: 0, length: inline.length))
        result.append(inline)
        return result
    }

    private func renderHorizontalRule() -> NSAttributedString {
        return NSAttributedString(
            string: "─────────────────────────────────────────",
            attributes: [
                .font: NSFont.systemFont(ofSize: 4),
                .foregroundColor: NSColor.separatorColor,
            ]
        )
    }

    // MARK: - Image Rendering

    private func renderImage(alt: String, urlString: String, explicitWidth: CGFloat?, explicitHeight: CGFloat?) -> NSAttributedString {
        let attachment = NSTextAttachment()

        if let cached = MarkdownImageCache.shared.object(forKey: urlString as NSString) {
            let sized = sizeImage(cached, explicitWidth: explicitWidth, explicitHeight: explicitHeight)
            attachment.image = sized
            let attrStr = NSMutableAttributedString(attachment: attachment)
            if !alt.isEmpty {
                attrStr.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                attrStr.append(NSAttributedString(string: alt, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            return attrStr
        }

        let placeholderW: CGFloat = explicitWidth ?? 200
        let placeholderH: CGFloat = explicitHeight ?? 40
        let placeholder = NSImage(size: NSSize(width: placeholderW, height: placeholderH))
        placeholder.lockFocus()
        NSColor.separatorColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: placeholder.size), xRadius: 6, yRadius: 6).fill()
        let loadingStr = (alt.isEmpty ? "Loading image…" : alt) as NSString
        let loadingAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textSize = loadingStr.size(withAttributes: loadingAttrs)
        loadingStr.draw(
            at: NSPoint(x: (placeholderW - textSize.width) / 2, y: (placeholderH - textSize.height) / 2),
            withAttributes: loadingAttrs
        )
        placeholder.unlockFocus()

        attachment.image = placeholder

        if let url = URL(string: urlString) {
            pendingAttachments.append((attachment: attachment, url: url, explicitWidth: explicitWidth, explicitHeight: explicitHeight))
        }

        let attrStr = NSMutableAttributedString(attachment: attachment)
        if !alt.isEmpty {
            attrStr.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
            attrStr.append(NSAttributedString(string: alt, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return attrStr
    }

    private func loadPendingImages() {
        let attachments = pendingAttachments
        pendingAttachments = []

        for entry in attachments {
            let attachmentBox = WeakTextAttachmentBox(entry.attachment)
            let url = entry.url
            let explicitWidth = entry.explicitWidth
            let explicitHeight = entry.explicitHeight

            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let self, let attachment = attachmentBox.attachment else { return }
                    MarkdownImageCache.shared.setObject(
                        image,
                        forKey: url.absoluteString as NSString,
                        cost: self.estimatedImageMemoryCost(image)
                    )

                    let sized = self.sizeImage(image, explicitWidth: explicitWidth, explicitHeight: explicitHeight)
                    attachment.image = sized
                    self.layoutManager?.invalidateLayout(
                        forCharacterRange: NSRange(location: 0, length: self.textStorage?.length ?? 0),
                        actualCharacterRange: nil
                    )
                    self.needsDisplay = true
                }
            }.resume()
        }
    }

    private func sizeImage(_ image: NSImage, explicitWidth: CGFloat?, explicitHeight: CGFloat?) -> NSImage {
        let containerWidth = max((textContainer?.size.width ?? 400) - 20, 100)
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }

        var targetWidth: CGFloat
        var targetHeight: CGFloat

        if let ew = explicitWidth, let eh = explicitHeight {
            targetWidth = min(ew, containerWidth)
            targetHeight = eh * (targetWidth / ew)
        } else if let ew = explicitWidth {
            targetWidth = min(ew, containerWidth)
            targetHeight = originalSize.height * (targetWidth / originalSize.width)
        } else if let eh = explicitHeight {
            targetHeight = eh
            targetWidth = originalSize.width * (eh / originalSize.height)
            if targetWidth > containerWidth {
                targetWidth = containerWidth
                targetHeight = originalSize.height * (targetWidth / originalSize.width)
            }
        } else {
            if originalSize.width <= containerWidth {
                return image
            }
            targetWidth = containerWidth
            targetHeight = originalSize.height * (targetWidth / originalSize.width)
        }

        let newSize = NSSize(width: targetWidth, height: targetHeight)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .sourceOver,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private func estimatedImageMemoryCost(_ image: NSImage) -> Int {
        if let rep = image.representations.first {
            let pixelsWide = max(1, rep.pixelsWide)
            let pixelsHigh = max(1, rep.pixelsHigh)
            return pixelsWide * pixelsHigh * 4
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let width = max(1, Int(image.size.width * scale))
        let height = max(1, Int(image.size.height * scale))
        return width * height * 4
    }

    // MARK: - Inline Markdown Parser

    private func parseInline(_ text: String, baseFont: NSFont) -> NSAttributedString {
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
                    // CommonMark: strip one leading + trailing space when
                    // content both starts and ends with space but isn't blank.
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

        let issuePattern = "(?<![\\w/&§])#(\\d+)(?!\\w)"
        if let regex = try? NSRegularExpression(pattern: issuePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()
            for match in matches {
                guard let numRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let issueNumber = String(result[numRange])
                let url = "https://github.com/\(Self.issueRepoSlug)/issues/\(issueNumber)"
                links.append((text: "#\(issueNumber)", url: url))
                result.replaceSubrange(fullRange, with: "§LINK\(links.count - 1)§")
            }
        }

        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "§BOLD§$1§/BOLD§", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "§BOLD§$1§/BOLD§", options: .regularExpression)

        result = result.replacingOccurrences(of: "(?<![§])\\*([^*]+)\\*(?![§])", with: "§ITALIC§$1§/ITALIC§", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![§])_([^_]+)_(?![§])", with: "§ITALIC§$1§/ITALIC§", options: .regularExpression)

        result = result.replacingOccurrences(of: "~~(.+?)~~", with: "§STRIKE§$1§/STRIKE§", options: .regularExpression)

        let attributed = NSMutableAttributedString()
        var current = result

        while !current.isEmpty {
            if let boldStart = current.range(of: "§BOLD§") {
                let before = String(current[..<boldStart.lowerBound])
                attributed.append(processPlain(before, baseFont: baseFont, codeSpans: codeSpans, links: links))
                current = String(current[boldStart.upperBound...])

                if let boldEnd = current.range(of: "§/BOLD§") {
                    let boldText = String(current[..<boldEnd.lowerBound])
                    let boldFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
                    attributed.append(NSAttributedString(string: boldText, attributes: [
                        .font: boldFont,
                        .foregroundColor: NSColor.labelColor,
                    ]))
                    current = String(current[boldEnd.upperBound...])
                }
            } else if let italicStart = current.range(of: "§ITALIC§") {
                let before = String(current[..<italicStart.lowerBound])
                attributed.append(processPlain(before, baseFont: baseFont, codeSpans: codeSpans, links: links))
                current = String(current[italicStart.upperBound...])

                if let italicEnd = current.range(of: "§/ITALIC§") {
                    let italicText = String(current[..<italicEnd.lowerBound])
                    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                    attributed.append(NSAttributedString(string: italicText, attributes: [
                        .font: italicFont,
                        .foregroundColor: NSColor.labelColor,
                    ]))
                    current = String(current[italicEnd.upperBound...])
                }
            } else if let strikeStart = current.range(of: "§STRIKE§") {
                let before = String(current[..<strikeStart.lowerBound])
                attributed.append(processPlain(before, baseFont: baseFont, codeSpans: codeSpans, links: links))
                current = String(current[strikeStart.upperBound...])

                if let strikeEnd = current.range(of: "§/STRIKE§") {
                    let strikeText = String(current[..<strikeEnd.lowerBound])
                    attributed.append(NSAttributedString(string: strikeText, attributes: [
                        .font: baseFont,
                        .foregroundColor: NSColor.labelColor,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ]))
                    current = String(current[strikeEnd.upperBound...])
                }
            } else {
                attributed.append(processPlain(current, baseFont: baseFont, codeSpans: codeSpans, links: links))
                break
            }
        }

        return attributed
    }

    private func processPlain(_ text: String, baseFont: NSFont, codeSpans: [String], links: [(text: String, url: String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var current = text

        while !current.isEmpty {
            if let codeMatch = current.range(of: "§CODE(\\d+)§", options: .regularExpression) {
                let before = String(current[..<codeMatch.lowerBound])
                result.append(NSAttributedString(string: before, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor]))

                let matchStr = String(current[codeMatch])
                if let indexMatch = matchStr.range(of: "\\d+", options: .regularExpression),
                   let index = Int(matchStr[indexMatch]),
                   index < codeSpans.count {
                    result.append(NSAttributedString(string: codeSpans[index], attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.15),
                    ]))
                }

                current = String(current[codeMatch.upperBound...])
            } else if let linkMatch = current.range(of: "§LINK(\\d+)§", options: .regularExpression) {
                let before = String(current[..<linkMatch.lowerBound])
                result.append(NSAttributedString(string: before, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor]))

                let matchStr = String(current[linkMatch])
                if let indexMatch = matchStr.range(of: "\\d+", options: .regularExpression),
                   let index = Int(matchStr[indexMatch]),
                   index < links.count {
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: baseFont,
                        .foregroundColor: NSColor.controlAccentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                    if let url = URL(string: links[index].url) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: links[index].text, attributes: attrs))
                }

                current = String(current[linkMatch.upperBound...])
            } else {
                result.append(NSAttributedString(string: current, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor]))
                break
            }
        }

        return result
    }

    // MARK: - Block Parsing

    private func parseBlocks(_ markdown: String) -> [MarkdownBlock] {
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

            if let imgMatch = Self.parseImgTag(trimmed) {
                blocks.append(.image(alt: imgMatch.alt, url: imgMatch.src, width: imgMatch.width, height: imgMatch.height))
                i += 1
                continue
            }

            if let mdImgMatch = Self.parseMarkdownImage(trimmed) {
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

    private static func parseImgTag(_ line: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?)? {
        guard line.range(of: "<img\\s", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }

        let srcPattern = "src\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let srcRegex = try? NSRegularExpression(pattern: srcPattern, options: .caseInsensitive),
              let srcMatch = srcRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let srcRange = Range(srcMatch.range(at: 1), in: line) else {
            return nil
        }
        let src = String(line[srcRange])

        var alt = ""
        let altPattern = "alt\\s*=\\s*[\"']([^\"']*)[\"']"
        if let altRegex = try? NSRegularExpression(pattern: altPattern, options: .caseInsensitive),
           let altMatch = altRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let altRange = Range(altMatch.range(at: 1), in: line) {
            alt = String(line[altRange])
        }

        let width = parseNumericAttribute("width", in: line)
        let height = parseNumericAttribute("height", in: line)

        return (src: src, alt: alt, width: width, height: height)
    }

    private static func parseMarkdownImage(_ line: String) -> (alt: String, url: String)? {
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
