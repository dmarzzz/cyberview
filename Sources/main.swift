// CyberView — a frameless specimen viewer that dresses content in the
// Ghostty HUD frame (port of ~/.config/ghostty/shaders/hud-overlay.glsl).
//
// Follows the live terminal profile: reads ~/.config/ghostty/config at launch
// (background, opacity, padding) and mirrors ~/.config/task-tint/task.zsh —
// each file's name is hashed to a hue exactly like `task <name>`, so every
// window gets its own frame color + subtle bg tint, same file → same color.
//
// Renderers are pluggable: images and markdown today; add a type to
// `renderers` below for more.

import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Ghostty profile (parsed from ~/.config/ghostty/config)

struct GhosttyProfile {
    var backgroundOpacity: CGFloat = 0.85   // background-opacity
    var background = NSColor.black          // background
    var paddingX: CGFloat = 14              // window-padding-x
    var paddingY: CGFloat = 12              // window-padding-y

    // Viewer runs a touch clearer than the terminal so the wallpaper reads through.
    var viewerAlpha: CGFloat { backgroundOpacity * 0.85 }

    static func load() -> GhosttyProfile {
        var profile = GhosttyProfile()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return profile }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background-opacity":
                if let v = Double(value) { profile.backgroundOpacity = CGFloat(v) }
            case "background":
                if let c = NSColor(ghosttyHex: value) { profile.background = c }
            case "window-padding-x":
                if let v = Double(value) { profile.paddingX = CGFloat(v) }
            case "window-padding-y":
                if let v = Double(value) { profile.paddingY = CGFloat(v) }
            default: break
            }
        }
        return profile
    }
}

extension NSColor {
    convenience init?(ghosttyHex value: String) {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((n >> 16) & 0xff) / 255,
                  green: CGFloat((n >> 8) & 0xff) / 255,
                  blue: CGFloat(n & 0xff) / 255, alpha: 1)
    }

    /// hsl2rgb, same math as hud-overlay.glsl / colorsys.hls_to_rgb
    static func hsl(hue: CGFloat, saturation s: CGFloat, lightness l: CGFloat) -> NSColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) / 360)
        if s < 1e-4 { return NSColor(srgbRed: l, green: l, blue: l, alpha: 1) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: CGFloat) -> CGFloat {
            var t = t0.truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return NSColor(srgbRed: channel(h + 1 / 3), green: channel(h), blue: channel(h - 1 / 3), alpha: 1)
    }
}

// MARK: - Task tint (mirrors ~/.config/task-tint/task.zsh + hud-overlay.glsl)

struct TaskTint {
    let hue: CGFloat
    /// taskColor() in hud-overlay.glsl: hsl(hue, 0.90, 0.55)
    var frame: NSColor { .hsl(hue: hue, saturation: 0.90, lightness: 0.55) }
    /// _TASK_L_SUBTLE=0.10 _TASK_S=0.80 — the settled terminal bg tint
    var background: NSColor { .hsl(hue: hue, saturation: 0.80, lightness: 0.10) }

    /// _task_hue_from_name: sha256(name), first 4 hex chars, mod 360
    init(name: String) {
        let digest = SHA256.hash(data: Data(name.utf8))
        let bytes = Array(digest)
        let first4hex = UInt32(bytes[0]) << 8 | UInt32(bytes[1])
        hue = CGFloat(first4hex % 360)
    }
}

enum Theme {
    static let terminalGreen = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    static let linkCyan = NSColor(srgbRed: 0.35, green: 0.9, blue: 1, alpha: 1)
    static let cornerRadius: CGFloat = 10
    static let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
}

let profile = GhosttyProfile.load()

// MARK: - Renderer registry

struct RenderResult {
    let view: NSView
    let naturalSize: NSSize
    var lockAspect = true
    /// Override the window translucency — text content wants more contrast than art.
    var backgroundAlpha: CGFloat? = nil
}

protocol Renderer {
    static func canRender(_ url: URL) -> Bool
    /// Returns nil if the file can't be read.
    static func make(url: URL) -> RenderResult?
}

/// Image host with zoom. At rest it tracks the window (fit); the first pinch,
/// option-scroll, or zoom command hands control to the user until Fit resets it.
final class ZoomingScrollView: NSScrollView {
    var userZoomed = false

    override func layout() {
        super.layout()
        guard !userZoomed, let doc = documentView,
              doc.frame.width > 0, doc.frame.height > 0 else { return }
        magnification = min(contentSize.width / doc.frame.width,
                            contentSize.height / doc.frame.height)
    }

    override func magnify(with event: NSEvent) {
        userZoomed = true
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        userZoomed = true
        super.smartMagnify(with: event)
    }

    // option-scroll zooms about the cursor; plain scroll pans as usual
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let doc = documentView else {
            super.scrollWheel(with: event)
            return
        }
        userZoomed = true
        let factor = pow(1.01, event.scrollingDeltaY)
        let center = doc.convert(event.locationInWindow, from: nil)
        setMagnification(clamp(magnification * factor), centeredAt: center)
    }

    func stepZoom(_ factor: CGFloat) {
        userZoomed = true
        // clip-view bounds live in document coordinates, so mid = visible center
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(clamp(magnification * factor), centeredAt: center)
    }

    func actualSize() {
        userZoomed = true
        magnification = 1
    }

    func fitToWindow() {
        userZoomed = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func clamp(_ m: CGFloat) -> CGFloat { min(max(m, minMagnification), maxMagnification) }
}

struct ImageRenderer: Renderer {
    static func canRender(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func make(url: URL) -> RenderResult? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var size = image.size
        if let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
           rep.pixelsWide > 0 {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true

        let scroll = ZoomingScrollView()
        scroll.documentView = imageView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32

        return RenderResult(view: scroll, naturalSize: size, lockAspect: true)
    }
}

// MARK: - Markdown renderer — terminal-flavored type in the same chrome

/// NSScrollView leaves the document view at its authored width, so a narrowed
/// window clips the prose instead of rewrapping it. Pin the text to the clip
/// view's width on every layout pass and it reflows.
final class ReflowingScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        if abs(textView.frame.width - width) > 0.5 {
            textView.frame.size.width = width
        }
        textView.textContainer?.containerSize = NSSize(
            width: width - 2 * textView.textContainerInset.width,
            height: .greatestFiniteMagnitude)
    }
}

struct MarkdownRenderer: Renderer {
    static let pageWidth: CGFloat = 760

    static func canRender(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    static func make(url: URL) -> RenderResult? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let tint = TaskTint(name: url.lastPathComponent)
        let baseURL = url.deletingLastPathComponent()
        var openDetails = Set<Int>()
        if ProcessInfo.processInfo.environment["CYBERVIEW_EXPAND"] != nil {
            let info = detailsInfo(in: source)
            openDetails = Set(0..<info.count).subtracting(info.defaultOpen)
        }
        let rendered = render(markdown: source, tint: tint, baseURL: baseURL, open: openDetails)

        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 100))
        textView.source = source
        textView.tint = tint
        textView.baseURL = baseURL
        textView.openDetails = openDetails
        #if DEBUG
        if let fragment = ProcessInfo.processInfo.environment["CYBERVIEW_SELFTEST_ANCHOR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                textView.clicked(onLink: URL(string: "#" + fragment) as Any, at: 0)
                FileHandle.standardError.write("selftest anchor toggled=\(textView.openDetails.sorted())\n".data(using: .utf8)!)
            }
        }
        if ProcessInfo.processInfo.environment["CYBERVIEW_SELFTEST_CLICK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { textView.selfTestClickFirstToggle() }
        }
        #endif
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.foregroundColor: Theme.linkCyan,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .cursor: NSCursor.pointingHand]
        textView.textStorage?.setAttributedString(rendered)

        // measure natural height at page width
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
        }
        let contentHeight = (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 400) + 40

        let scroll = ReflowingScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        return RenderResult(view: scroll,
                            naturalSize: NSSize(width: pageWidth, height: max(240, contentHeight)),
                            lockAspect: false,
                            // prose needs contrast the wallpaper would steal; at 0.96 a
                            // bright page behind the window still ghosted through the text
                            backgroundAlpha: 0.985)
    }

    // AttributedString(markdown:) parses structure into presentation intents;
    // walk the runs and dress them in terminal type: green mono body, tint
    // headings, bright code on dark boxes.
    static func render(markdown raw: String, tint: TaskTint, baseURL: URL? = nil,
                       open: Set<Int> = [], loadImages: Bool = true) -> NSAttributedString {
        var detailsCounter = 0
        var defaults = Set<Int>()
        let source = expandDetails(convertInlineHTML(raw), toggled: open, counter: &detailsCounter,
                                   defaultOpen: &defaults)
        let body = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bodyColor = Theme.terminalGreen.withAlphaComponent(0.88)
        let fallback: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: bodyColor]

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: fallback)
        }

        let out = NSMutableAttributedString()
        var lastBlockIDs: [Int]? = nil

        // tables become real NSTextTable grids: one paragraph per cell, blocks
        // cached per (table, row, column) so inline runs share their cell
        var tables: [Int: NSTextTable] = [:]
        var tableRowCounter: [Int: Int] = [:]
        var tableLastRowKey: [Int: Int] = [:]
        var cellBlocks: [String: NSTextTableBlock] = [:]
        var lastWasTable = false
        var lastWasCode = false
        var lastMarkedListItem: Int? = nil
        var headingStart: Int? = nil
        var slugCounts: [String: Int] = [:]

        // headings carry their GitHub-style slug so "#fragment" links can find them
        func closeHeading() {
            guard let start = headingStart, out.length > start else { headingStart = nil; return }
            let range = NSRange(location: start, length: out.length - start)
            let base = slug(out.attributedSubstring(from: range).string)
            let n = slugCounts[base, default: 0]
            slugCounts[base] = n + 1
            out.addAttribute(.cvAnchor, value: n == 0 ? base : "\(base)-\(n)", range: range)
            headingStart = nil
        }

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)

            var headingLevel = 0
            var isCodeBlock = false
            var isQuote = false
            var isThematicBreak = false
            var isListItem = false
            var ordered = false
            var ordinal = 0
            var listDepth = 0
            var listItemID: Int? = nil
            var listKindKnown = false
            var cellColumn: Int? = nil
            var rowIndex: Int? = nil
            var tableID: Int? = nil
            var tableColumns = 0
            var blockIDs: [Int] = []

            if let intent = run.presentationIntent {
                for comp in intent.components {
                    blockIDs.append(comp.identity)
                    switch comp.kind {
                    case .header(let level): headingLevel = level
                    case .codeBlock: isCodeBlock = true
                    case .blockQuote: isQuote = true
                    case .thematicBreak: isThematicBreak = true
                    case .listItem(let o):
                        listDepth += 1
                        if !isListItem { isListItem = true; ordinal = o; listItemID = comp.identity }
                    case .orderedList: if !listKindKnown { ordered = true; listKindKnown = true }
                    case .unorderedList: if !listKindKnown { ordered = false; listKindKnown = true }
                    case .table(let cols): tableID = comp.identity; tableColumns = cols.count
                    case .tableCell(let c): cellColumn = c
                    case .tableRow(let r): rowIndex = r
                    case .tableHeaderRow: rowIndex = -1
                    default: break
                    }
                }
            }

            // block boundaries
            let newBlock = blockIDs != lastBlockIDs
            if newBlock { closeHeading() }
            if newBlock, out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: fallback))
            }

            // resolve this run's table cell block, if any
            var cellBlock: NSTextTableBlock? = nil
            let isHeaderCell = rowIndex == -1
            if let tid = tableID, let col = cellColumn, let rowKey = rowIndex {
                let table: NSTextTable
                if let t = tables[tid] { table = t } else {
                    table = NSTextTable()
                    table.numberOfColumns = max(tableColumns, 1)
                    table.layoutAlgorithm = .automaticLayoutAlgorithm
                    table.collapsesBorders = true
                    table.hidesEmptyCells = false
                    tables[tid] = table
                    tableRowCounter[tid] = 0
                    tableLastRowKey[tid] = rowKey
                }
                if tableLastRowKey[tid] != rowKey {
                    tableRowCounter[tid, default: 0] += 1
                    tableLastRowKey[tid] = rowKey
                }
                let row = tableRowCounter[tid, default: 0]
                let key = "\(tid):\(row):\(col)"
                if let b = cellBlocks[key] { cellBlock = b } else {
                    let b = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                             startingColumn: col, columnSpan: 1)
                    b.setWidth(0.5, type: .absoluteValueType, for: .border)
                    b.setBorderColor(tint.frame.withAlphaComponent(0.38))
                    b.setWidth(5, type: .absoluteValueType, for: .padding)
                    b.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                    b.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                    if isHeaderCell { b.backgroundColor = tint.frame.withAlphaComponent(0.14) }
                    cellBlocks[key] = b
                    cellBlock = b
                }
            }

            if isThematicBreak {
                if newBlock {
                    out.append(NSAttributedString(
                        string: "────────────────────────────\n",
                        attributes: [.font: body,
                                     .foregroundColor: tint.frame.withAlphaComponent(0.4)]))
                }
                lastBlockIDs = blockIDs
                continue
            }

            // paragraph style
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = isCodeBlock ? 2 : 9
            para.lineHeightMultiple = 1.15
            if headingLevel > 0 { para.paragraphSpacingBefore = 10 }
            if let cellBlock {
                para.textBlocks = [cellBlock]
                para.paragraphSpacing = 0
                para.lineHeightMultiple = 1.1
            } else if lastWasTable, newBlock {
                para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, 12)
            } else if lastWasCode, newBlock, !isCodeBlock {
                para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, 10)
            }
            if isListItem || isQuote {
                // nested lists step in one level per enclosing list item
                let inset = CGFloat(max(listDepth, 1) - 1) * 22
                para.headIndent = inset + 24
                para.firstLineHeadIndent = inset
            }
            if isCodeBlock {
                para.headIndent = 16
                para.firstLineHeadIndent = 16
                para.lineHeightMultiple = 1.05
            }

            // typography
            var font = body
            var color = bodyColor
            var background: NSColor? = nil

            if headingLevel > 0 {
                let sizes: [CGFloat] = [22, 18, 15.5, 14, 13, 13]
                font = NSFont.monospacedSystemFont(ofSize: sizes[min(headingLevel, 6) - 1], weight: .bold)
                color = tint.frame
            }
            if isQuote {
                color = bodyColor.withAlphaComponent(0.55)
            }
            if isCodeBlock {
                color = NSColor(srgbRed: 0.80, green: 1.0, blue: 0.84, alpha: 1)
                background = NSColor.black.withAlphaComponent(0.45)
            }
            if cellBlock != nil {
                font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                if isHeaderCell { color = tint.frame }
            }

            var bold = headingLevel > 0 || (cellBlock != nil && isHeaderCell)
            var italic = isQuote
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { bold = true }
                if inline.contains(.emphasized) { italic = true }
                if inline.contains(.code) {
                    color = NSColor(srgbRed: 0.80, green: 1.0, blue: 0.84, alpha: 1)
                    background = NSColor.black.withAlphaComponent(0.45)
                }
            }
            if bold || italic {
                var traits = NSFontDescriptor.SymbolicTraits()
                if bold { traits.insert(.bold) }
                if italic { traits.insert(.italic) }
                let d = font.fontDescriptor.withSymbolicTraits(traits)
                if let f = NSFont(descriptor: d, size: font.pointSize) { font = f }
            }

            // list / quote markers on the first run of their block
            if isListItem, newBlock, listItemID != lastMarkedListItem {
                lastMarkedListItem = listItemID
                let marker = ordered ? "\(ordinal). " : (listDepth > 1 ? "◦ " : "• ")
                out.append(NSAttributedString(string: marker, attributes: [
                    .font: body, .foregroundColor: tint.frame, .paragraphStyle: para]))
            }
            if isQuote, newBlock {
                out.append(NSAttributedString(string: "│ ", attributes: [
                    .font: body, .foregroundColor: tint.frame.withAlphaComponent(0.6),
                    .paragraphStyle: para]))
            }

            // code blocks keep their own trailing newline; trim it for spacing
            if isCodeBlock, text.hasSuffix("\n") { text.removeLast() }

            // local images render inline, scaled to the page
            if loadImages, let imageURL = run.imageURL {
                let resolved = imageURL.scheme == nil
                    ? baseURL?.appendingPathComponent(imageURL.relativeString.removingPercentEncoding
                                                      ?? imageURL.relativeString)
                    : (imageURL.isFileURL ? imageURL : nil)
                if let resolved, let image = NSImage(contentsOf: resolved), image.size.width > 0 {
                    let maxWidth = pageWidth - 60
                    let scale = min(1, maxWidth / image.size.width)
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale,
                                               height: image.size.height * scale)
                    // a line-height multiple would scale with the image's height
                    let imagePara = para.mutableCopy() as! NSMutableParagraphStyle
                    imagePara.lineHeightMultiple = 1
                    imagePara.paragraphSpacingBefore = 4
                    let shown = NSMutableAttributedString(attachment: attachment)
                    shown.addAttribute(.paragraphStyle, value: imagePara,
                                       range: NSRange(location: 0, length: shown.length))
                    out.append(shown)
                    lastBlockIDs = blockIDs
                    lastWasTable = false
                    lastWasCode = false
                    continue
                }
            }

            if headingLevel > 0, headingStart == nil { headingStart = out.length }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: para]
            if let background { attrs[.backgroundColor] = background }
            if let link = run.link, link.scheme == "cyberview-toggle", let id = Int(link.host ?? "") {
                // <details> disclosure line: click to fold or unfold
                let closing = link.path == "/close"
                attrs[.cvToggle] = id
                if closing { attrs[.cvToggleClose] = true }
                attrs[.cursor] = NSCursor.pointingHand
                attrs[.foregroundColor] = tint.frame.withAlphaComponent(closing ? 0.45 : 1)
                if !closing, let f = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold),
                                           size: font.pointSize) { attrs[.font] = f }
            } else if let link = run.link { attrs[.link] = link }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            out.append(NSAttributedString(string: text, attributes: attrs))
            lastBlockIDs = blockIDs
            lastWasTable = cellBlock != nil
            lastWasCode = isCodeBlock
        }
        closeHeading()
        return out
    }

    // MARK: HTML that Markdown files lean on

    static func slug(_ heading: String) -> String {
        let kept = heading.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }

    /// `<img src alt>` becomes a Markdown image; `<br>` becomes a hard break.
    static func convertInlineHTML(_ s: String) -> String {
        guard let img = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else { return s }
        func attribute(_ name: String, in tag: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*\"([^\"]*)\"", options: [.caseInsensitive]),
                  let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let r = Range(m.range(at: 1), in: tag) else { return nil }
            return String(tag[r])
        }
        var out = s
        for m in img.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let tag = String(out[r])
            guard let src = attribute("src", in: tag) else { continue }
            let alt = (attribute("alt", in: tag) ?? "").replacingOccurrences(of: "]", with: ")")
            out.replaceSubrange(r, with: "![\(alt)](\(src.replacingOccurrences(of: " ", with: "%20")))")
        }
        return out.replacingOccurrences(of: "<br\\s*/?>", with: "  \n", options: [.regularExpression, .caseInsensitive])
    }

    static func detailsInfo(in source: String) -> (count: Int, defaultOpen: Set<Int>) {
        var n = 0
        var defaults = Set<Int>()
        _ = expandDetails(source, toggled: [], counter: &n, defaultOpen: &defaults)
        return (n, defaults)
    }

    /// `<details><summary>…</summary>…</details>` becomes a disclosure line. Closed blocks drop
    /// their body. Ids count in document order whether or not a block is open, so they stay stable.
    /// A block is open when its `open` attribute and its toggled state differ. A summary that holds
    /// a heading (`<summary><h2>…</h2></summary>`) becomes a heading-sized disclosure line.
    static func expandDetails(_ s: String, toggled: Set<Int>, counter: inout Int,
                              defaultOpen: inout Set<Int>) -> String {
        var out = ""
        var rest = Substring(s)
        while let start = rest.range(of: "<details", options: .caseInsensitive) {
            out += rest[..<start.lowerBound]
            guard let tagEnd = rest[start.upperBound...].range(of: ">") else { return out + rest[start.lowerBound...] }
            var depth = 1
            var cursor = tagEnd.upperBound
            var close: Range<Substring.Index>? = nil
            while depth > 0 {
                guard let nextClose = rest[cursor...].range(of: "</details>", options: .caseInsensitive) else { break }
                if let nextOpen = rest[cursor...].range(of: "<details", options: .caseInsensitive),
                   nextOpen.lowerBound < nextClose.lowerBound {
                    depth += 1
                    cursor = nextOpen.upperBound
                } else {
                    depth -= 1
                    cursor = nextClose.upperBound
                    if depth == 0 { close = nextClose }
                }
            }
            guard let close else { return out + rest[start.lowerBound...] }   // unbalanced: leave as written
            var inner = String(rest[tagEnd.upperBound..<close.lowerBound])
            let tagText = String(rest[start.lowerBound..<tagEnd.upperBound])
            let hasOpenAttribute = tagText.range(of: "\\sopen\\b", options: [.regularExpression, .caseInsensitive]) != nil
            var headingLevel = 0
            var summary = "details"
            if let so = inner.range(of: "<summary>", options: .caseInsensitive),
               let sc = inner.range(of: "</summary>", options: .caseInsensitive), so.upperBound <= sc.lowerBound {
                let rawSummary = String(inner[so.upperBound..<sc.lowerBound])
                if let h = rawSummary.range(of: "<h[1-6]", options: [.regularExpression, .caseInsensitive]),
                   let level = Int(String(rawSummary[h].last!)) { headingLevel = level }
                summary = rawSummary
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                inner.removeSubrange(so.lowerBound..<sc.upperBound)
            }
            let id = counter
            counter += 1
            if hasOpenAttribute { defaultOpen.insert(id) }
            let bodyText = expandDetails(inner, toggled: toggled, counter: &counter, defaultOpen: &defaultOpen)
            let label = summary.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            let hashes = headingLevel > 0 ? String(repeating: "#", count: headingLevel) + " " : ""
            if hasOpenAttribute != toggled.contains(id) {
                out += "\n\n\(hashes)[▾ \(label)](cyberview-toggle://\(id))\n\n" + bodyText
                    + "\n\n[▴ close · \(label)](cyberview-toggle://\(id)/close)\n\n"
            } else {
                out += "\n\n\(hashes)[▸ \(label)](cyberview-toggle://\(id))\n\n"
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}

extension NSAttributedString.Key {
    static let cvToggle = NSAttributedString.Key("cyberview.toggle")
    static let cvAnchor = NSAttributedString.Key("cyberview.anchor")
    static let cvToggleClose = NSAttributedString.Key("cyberview.toggle.close")
}

/// The markdown page. It keeps the source so a click on a disclosure line can re-render,
/// follows "#fragment" links to headings, and opens relative links next to the document.
final class MarkdownTextView: NSTextView {
    var source = ""
    var tint: TaskTint!
    var baseURL: URL?
    var openDetails = Set<Int>()

    func rerender() {
        let clip = enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        textStorage?.setAttributedString(MarkdownRenderer.render(markdown: source, tint: tint,
                                                                 baseURL: baseURL, open: openDetails))
        if let lm = layoutManager, let tc = textContainer { lm.ensureLayout(for: tc) }
        if let clip, let origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func setAllDetails(open: Bool) {
        let info = MarkdownRenderer.detailsInfo(in: source)
        openDetails = open ? Set(0..<info.count).subtracting(info.defaultOpen) : info.defaultOpen
        rerender()
    }

    override func mouseDown(with event: NSEvent) {
        if let id = toggle(at: convert(event.locationInWindow, from: nil)) {
            if openDetails.contains(id) { openDetails.remove(id) } else { openDetails.insert(id) }
            rerender()
            return
        }
        super.mouseDown(with: event)
    }

    /// A disclosure line is clickable across its whole width.
    private func toggle(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        var lineRange = NSRange()
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        guard lineRect.minY <= p.y, p.y <= lineRect.maxY else { return nil }
        let chars = lm.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
        guard chars.location < ts.length else { return nil }
        return ts.attribute(.cvToggle, at: chars.location, effectiveRange: nil) as? Int
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = (link as? URL) ?? (link as? String).flatMap({ URL(string: $0) }) else {
            return super.clicked(onLink: link, at: charIndex)
        }
        let text = url.relativeString
        if text.hasPrefix("#") { scrollToAnchor(String(text.dropFirst())); return }
        if url.scheme == nil, let baseURL {
            let path = text.components(separatedBy: "#")[0]
            let target = baseURL.appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
            if FileManager.default.fileExists(atPath: target.path) {
                if renderers.contains(where: { $0.canRender(target) }) {
                    AppDelegate.shared?.open(url: target)
                } else {
                    NSWorkspace.shared.open(target)
                }
                return
            }
        }
        super.clicked(onLink: link, at: charIndex)
    }

    #if DEBUG
    /// Sends a mouseDown to the right of the first disclosure line, through the normal hit-testing.
    func selfTestClickFirstToggle() {
        guard let ts = textStorage, let lm = layoutManager, let tc = textContainer, let window else { return }
        var target: NSRange?
        ts.enumerateAttribute(.cvToggle, in: NSRange(location: 0, length: ts.length)) { value, range, stop in
            if value != nil { target = range; stop.pointee = true }
        }
        guard let target else { return }
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil), in: tc)
        let local = NSPoint(x: rect.maxX + textContainerOrigin.x + 120, y: rect.midY + textContainerOrigin.y)
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: convert(local, to: nil), modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
            mouseDown(with: event)
        }
        FileHandle.standardError.write("selftest open=\(openDetails.sorted())\n".data(using: .utf8)!)
    }
    #endif

    private func scrollToAnchor(_ fragment: String) {
        let wanted = MarkdownTextView.normalized(fragment.removingPercentEncoding ?? fragment)
        if scrollIfPresent(wanted) { return }
        // the heading may sit inside folded blocks: find the chain that hides it, open it, retry
        let info = MarkdownRenderer.detailsInfo(in: source)
        let everything = Set(0..<info.count).subtracting(info.defaultOpen)
        let probe = MarkdownRenderer.render(markdown: source, tint: tint, baseURL: baseURL,
                                            open: everything, loadImages: false)
        var stack: [Int] = []
        var chain: [Int]? = nil
        probe.enumerateAttributes(in: NSRange(location: 0, length: probe.length)) { attrs, _, stop in
            if let anchor = attrs[.cvAnchor] as? String, MarkdownTextView.normalized(anchor) == wanted {
                var found = stack
                if let own = attrs[.cvToggle] as? Int, !found.contains(own) { found.append(own) }
                chain = found
                stop.pointee = true
                return
            }
            guard let id = attrs[.cvToggle] as? Int else { return }
            if attrs[.cvToggleClose] != nil { if stack.last == id { stack.removeLast() } }
            else if stack.last != id { stack.append(id) }
        }
        guard let chain else { return }
        for id in chain where info.defaultOpen.contains(id) == openDetails.contains(id) {
            // currently closed: flip it
            if openDetails.contains(id) { openDetails.remove(id) } else { openDetails.insert(id) }
        }
        rerender()
        _ = scrollIfPresent(wanted)
    }

    /// GitHub prefixes a hyphen when a heading starts with an emoji; compare without edge hyphens.
    private static func normalized(_ slug: String) -> String {
        slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func scrollIfPresent(_ wanted: String) -> Bool {
        guard let ts = textStorage, let lm = layoutManager, let tc = textContainer,
              let clip = enclosingScrollView?.contentView else { return false }
        var found = false
        ts.enumerateAttribute(.cvAnchor, in: NSRange(location: 0, length: ts.length)) { value, range, stop in
            guard let anchor = value as? String, MarkdownTextView.normalized(anchor) == wanted else { return }
            lm.ensureLayout(for: tc)
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let top = max(0, rect.minY + textContainerOrigin.y - 12)
            let maxY = max(0, bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(top, maxY)))
            enclosingScrollView?.reflectScrolledClipView(clip)
            found = true
            stop.pointee = true
        }
        return found
    }
}

let renderers: [Renderer.Type] = [ImageRenderer.self, MarkdownRenderer.self]
// Future: TextRenderer, PDFRenderer, …

// MARK: - HUD frame view (port of hud-overlay.glsl)

final class HUDFrameView: NSView {
    // Shader constants, UV space
    private let M: CGFloat = 0.008
    private let CL: CGFloat = 0.065
    private let cgGap: CGFloat = 0.025
    private let hud: NSColor

    override var isFlipped: Bool { false }

    init(frame: NSRect, color: NSColor) {
        hud = color
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = hud.cgColor            // edge-glow stand-in
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 5
        layer?.shadowOffset = .zero
        startPulse()
    }

    required init?(coder: NSCoder) { fatalError() }

    // pulse = 0.7 + 0.3 sin(t · 1.3) → gentle opacity breathing
    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 2.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "hudPulse")
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    // frame is decoration only — let clicks fall through to content (text selection, links)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 20, h > 20 else { return }
        let mx = M * w, my = M * h
        let clx = CL * w, cly = CL * h
        let cw = max(1.5, 0.002 * h)     // corner bracket weight
        let fw: CGFloat = 0.75           // frame connecting-line weight

        func hline(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ weight: CGFloat, _ alpha: CGFloat) {
            hud.withAlphaComponent(alpha).setFill()
            NSRect(x: x0, y: y - weight / 2, width: x1 - x0, height: weight).fill()
        }
        func vline(_ y0: CGFloat, _ y1: CGFloat, _ x: CGFloat, _ weight: CGFloat, _ alpha: CGFloat) {
            hud.withAlphaComponent(alpha).setFill()
            NSRect(x: x - weight / 2, y: y0, width: weight, height: y1 - y0).fill()
        }

        // ── corner brackets (A_CORNER 0.50) ──
        let aC: CGFloat = 0.50
        let top = h - my, bot = my, lft = mx, rgt = w - mx
        hline(lft, lft + clx, top, cw, aC); vline(top - cly, top, lft, cw, aC)   // ┌
        hline(rgt - clx, rgt, top, cw, aC); vline(top - cly, top, rgt, cw, aC)   // ┐
        hline(lft, lft + clx, bot, cw, aC); vline(bot, bot + cly, lft, cw, aC)   // └
        hline(rgt - clx, rgt, bot, cw, aC); vline(bot, bot + cly, rgt, cw, aC)   // ┘

        // ── frame lines, split at midpoint (A_FRAME 0.15) ──
        let aF: CGFloat = 0.15
        let gx = clx + 0.01 * w, gy = cly + 0.01 * h
        let cgx = cgGap * w, cgy = cgGap * h
        hline(lft + gx, w / 2 - cgx, top, fw, aF); hline(w / 2 + cgx, rgt - gx, top, fw, aF)
        hline(lft + gx, w / 2 - cgx, bot, fw, aF); hline(w / 2 + cgx, rgt - gx, bot, fw, aF)
        vline(bot + gy, h / 2 - cgy, lft, fw, aF); vline(h / 2 + cgy, top - gy, lft, fw, aF)
        vline(bot + gy, h / 2 - cgy, rgt, fw, aF); vline(h / 2 + cgy, top - gy, rgt, fw, aF)

        // ── diamond markers at edge midpoints (A_DIAMOND 0.35) ──
        let dr = 0.005 * h
        for c in [NSPoint(x: w / 2, y: top), NSPoint(x: w / 2, y: bot),
                  NSPoint(x: lft, y: h / 2), NSPoint(x: rgt, y: h / 2)] {
            let d = NSBezierPath()
            d.move(to: NSPoint(x: c.x, y: c.y + dr))
            d.line(to: NSPoint(x: c.x + dr, y: c.y))
            d.line(to: NSPoint(x: c.x, y: c.y - dr))
            d.line(to: NSPoint(x: c.x - dr, y: c.y))
            d.close()
            hud.withAlphaComponent(0.35).setFill()
            d.fill()
        }

        // ── tick marks every 5%, larger at quarters (A_TICK 0.12) ──
        let aT: CGFloat = 0.12
        for i in 2...18 {
            let pos = CGFloat(i) * 0.05
            let major = (i == 5 || i == 10 || i == 15)
            let len = (major ? 0.009 : 0.005) * h
            let tw: CGFloat = major ? 1.2 : 0.8
            vline(top - len, top, pos * w, tw, aT)
            vline(bot, bot + len, pos * w, tw, aT)
            hline(lft, lft + len, pos * h, tw, aT)
            hline(rgt - len, rgt, pos * h, tw, aT)
        }
    }
}

// MARK: - Root view — keeps every layer aligned to the frame at any size

/// The HUD margins are proportional (UV space), so the content inset has to be
/// recomputed on every resize; baking it in at creation makes the content drift
/// out from under the brackets.
final class RootView: NSView {
    var content: NSView?
    var closeButton: NSView?
    /// Extra hover buttons laid out leftward from the close button, in order.
    var accessories: [NSView] = []
    var nameLabel: NSView?

    override func layout() {
        super.layout()
        let mx = 0.008 * bounds.width + profile.paddingX
        let my = 0.008 * bounds.height + profile.paddingY
        content?.frame = bounds.insetBy(dx: mx, dy: my)

        if let close = closeButton {
            close.frame.origin = NSPoint(x: bounds.maxX - mx - close.frame.width - 2,
                                         y: bounds.maxY - my - close.frame.height - 2)
            var x = close.frame.minX
            for button in accessories {
                x -= button.frame.width + 2
                button.frame.origin = NSPoint(x: x, y: close.frame.minY)
            }
        }
        if let label = nameLabel {
            label.frame.origin = NSPoint(x: mx + 2, y: 0.008 * bounds.height + 4)
        }
    }
}

// MARK: - Window

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }   // esc
        super.keyDown(with: event)
    }
}

final class ViewerController: NSWindowController, NSWindowDelegate {
    private var fileURL: URL!
    private var closeButton: NSButton!
    private var copyButton: NSButton!
    private var revealButton: NSButton!
    private var hoverButtons: [NSView] = []
    private var nameLabel: NSTextField!
    private var zoomView: ZoomingScrollView?
    private var copyGlyph: NSAttributedString?

    private static func hudButton(_ glyph: String, size: CGFloat, tint: NSColor,
                                  tip: String) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [.foregroundColor: tint,
                         .font: NSFont.systemFont(ofSize: size, weight: .light)])
        button.alphaValue = 0
        button.wantsLayer = true
        button.toolTip = tip
        return button
    }

    convenience init?(url: URL) {
        guard let renderer = renderers.first(where: { $0.canRender(url) }),
              let result = renderer.make(url: url) else { return nil }

        let tint = TaskTint(name: url.lastPathComponent)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = NSSize(width: 2 * profile.paddingX + 16, height: 2 * profile.paddingY + 16)
        var size = result.naturalSize
        let maxW = screen.width * 0.85 - chrome.width
        let maxH = screen.height * 0.85 - chrome.height
        if result.lockAspect {
            let scale = min(1, maxW / max(size.width, 1), maxH / max(size.height, 1))
            size = NSSize(width: size.width * scale, height: size.height * scale)
        } else {
            size = NSSize(width: min(size.width, maxW), height: min(size.height, maxH))
        }
        size = NSSize(width: max(220, size.width + chrome.width),
                      height: max(160, size.height + chrome.height))

        let window = ViewerWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 200, height: 150)
        if result.lockAspect { window.contentAspectRatio = size }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        self.init(window: window)
        window.delegate = self

        let root = RootView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = tint.background
            .withAlphaComponent(result.backgroundAlpha ?? profile.viewerAlpha).cgColor
        root.layer?.cornerRadius = Theme.cornerRadius
        root.layer?.masksToBounds = true
        window.contentView = root

        root.addSubview(result.view)
        root.content = result.view

        let hudView = HUDFrameView(frame: root.bounds, color: tint.frame)
        hudView.autoresizingMask = [.width, .height]
        root.addSubview(hudView)

        fileURL = url
        zoomView = result.view as? ZoomingScrollView

        // hover-reveal buttons — blend into the frame until you reach for them
        let close = Self.hudButton("✕", size: 15, tint: tint.frame, tip: "close")
        close.target = window
        close.action = #selector(NSWindow.close)
        root.addSubview(close)
        root.closeButton = close
        closeButton = close

        let copy = Self.hudButton("⧉", size: 13, tint: tint.frame, tip: "copy contents")
        copy.target = self
        copy.action = #selector(copyContents(_:))
        root.addSubview(copy)
        copyButton = copy
        copyGlyph = copy.attributedTitle

        let reveal = Self.hudButton("⌖", size: 14, tint: tint.frame, tip: "reveal in Finder")
        reveal.target = self
        reveal.action = #selector(revealInFinder(_:))
        root.addSubview(reveal)
        revealButton = reveal

        root.accessories = [copy, reveal]
        hoverButtons = [close, copy, reveal]

        // hover-only filename, terminal green
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.font = Theme.mono
        label.textColor = Theme.terminalGreen
        label.alphaValue = 0
        label.sizeToFit()
        root.addSubview(label)
        root.nameLabel = label
        nameLabel = label
        root.needsLayout = true

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        root.addTrackingArea(tracking)
        for button in hoverButtons {
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: ["view": button]))
        }

        window.center()
        window.title = url.lastPathComponent   // for Window menu / mission control
    }

    private func fade(_ view: NSView, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            view.animator().alphaValue = alpha
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let button = event.trackingArea?.userInfo?["view"] as? NSView {
            fade(button, to: 1.0)
        } else {
            hoverButtons.forEach { fade($0, to: 0.45) }
            fade(nameLabel, to: 0.55)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.userInfo?["view"] as? NSView {
            fade(button, to: 0.45)
        } else {
            hoverButtons.forEach { fade($0, to: 0) }
            fade(nameLabel, to: 0)
        }
    }

    // MARK: actions

    @objc private func copyContents(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            pb.setString(text, forType: .string)
        } else if let image = NSImage(contentsOf: fileURL) {
            pb.writeObjects([image])
        } else {
            pb.setString(fileURL.path, forType: .string)
        }
        // brief confirmation tick, then back to the glyph
        copyButton.attributedTitle = NSAttributedString(
            string: "✓",
            attributes: [.foregroundColor: Theme.terminalGreen,
                         .font: NSFont.systemFont(ofSize: 13, weight: .light)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, let glyph = self.copyGlyph else { return }
            self.copyButton.attributedTitle = glyph
        }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc func zoomIn(_ sender: Any?) { zoomView?.stepZoom(1.25) }
    @objc func zoomOut(_ sender: Any?) { zoomView?.stepZoom(1 / 1.25) }
    @objc func zoomActualSize(_ sender: Any?) { zoomView?.actualSize() }
    @objc func zoomToFit(_ sender: Any?) { zoomView?.fitToWindow() }

    private var markdownView: MarkdownTextView? {
        (window?.contentView as? RootView)?.content.flatMap { ($0 as? NSScrollView)?.documentView as? MarkdownTextView }
    }
    @objc func expandAllSections(_ sender: Any?) { markdownView?.setAllDetails(open: true) }
    @objc func collapseAllSections(_ sender: Any?) { markdownView?.setAllDetails(open: false) }

    override func responds(to aSelector: Selector!) -> Bool {
        // grey out zoom menu items on non-zoomable content (markdown)
        if aSelector == #selector(zoomIn(_:)) || aSelector == #selector(zoomOut(_:))
            || aSelector == #selector(zoomActualSize(_:)) || aSelector == #selector(zoomToFit(_:)) {
            return zoomView != nil
        }
        if aSelector == #selector(expandAllSections(_:)) || aSelector == #selector(collapseAllSections(_:)) {
            return (markdownView?.source.range(of: "<details", options: .caseInsensitive)) != nil
        }
        return super.responds(to: aSelector)
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.forget(self)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    private var controllers: [ViewerController] = []
    private var cascadePoint = NSPoint.zero

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        // direct CLI invocation (open(2)-launched files arrive via application(_:open:))
        let cliURLs = CommandLine.arguments.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        cliURLs.forEach(open(url:))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open(url:))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func open(url: URL) {
        guard let controller = ViewerController(url: url) else {
            NSSound.beep()
            return
        }
        if let window = controller.window {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func forget(_ controller: ViewerController) {
        controllers.removeAll { $0 === controller }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.image]
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(open(url:)) }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit CyberView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(ViewerController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(ViewerController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(ViewerController.zoomActualSize(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Fit to Window", action: #selector(ViewerController.zoomToFit(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Expand All Sections", action: #selector(ViewerController.expandAllSections(_:)), keyEquivalent: "e")
        let collapse = viewMenu.addItem(withTitle: "Collapse All Sections", action: #selector(ViewerController.collapseAllSections(_:)), keyEquivalent: "e")
        collapse.keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
