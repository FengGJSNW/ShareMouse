import AppKit
import ImageIO

@MainActor public final class MacClipboardAdapter {
    private var polling = false
    private var observed = NSPasteboard.general.changeCount
    private var timer: Task<Void, Never>?
    public var filesCopied: (([String], Bool) async throws -> Void)?
    public var contentCopied: ((ClipboardContent?) async throws -> Void)?
    public var copied: ((String?) async throws -> Void)?
    public var failed: (() -> Void)?
    public init() {}
    public var hasUnobservedChange: Bool { observed != NSPasteboard.general.changeCount }
    public func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300));
                guard let self, !Task.isCancelled else { return };
                await self.poll()
            }
        }
    }
    public func poll() async {
        let pasteboard = NSPasteboard.general
        guard observed != pasteboard.changeCount, !polling else { return };
        polling = true;
        defer { polling = false }
        let count = pasteboard.changeCount
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let content = (files?.isEmpty ?? true) ? try? readContent(pasteboard) : nil
        guard count == pasteboard.changeCount else { return };
        observed = count
        do {
            if let files, !files.isEmpty {
                try await filesCopied?(
                    files.compactMap { ($0 as? URL)?.path },
                    pasteboard.string(forType: .init("com.sharemouse.cut")) == "1")
            } else if let contentCopied {
                try await contentCopied(content)
            } else {
                try await copied?(content?.plainText)
            }
        } catch { failed?() }
    }
    private func readContent(_ pasteboard: NSPasteboard) throws -> ClipboardContent? {
        let text = pasteboard.string(forType: .string)
        if let png = pasteboard.data(forType: .png) { return ClipboardContent(kind: "png", data: png) }
        if let tiff = pasteboard.data(forType: .tiff), let source = CGImageSourceCreateWithData(tiff as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = properties[kCGImagePropertyPixelWidth] as? Int,
            let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w <= 16384, h <= 16384,
            w * h <= 64_000_000, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            return ClipboardContent(kind: "png", data: png)
        }
        if let url = pasteboard.string(forType: .URL) {
            return ClipboardContent(kind: "url", data: Data(url.utf8), plainText: text ?? url)
        }
        if let html = pasteboard.data(forType: .html) {
            return ClipboardContent(kind: "html", data: html, plainText: text)
        }
        if let rtf = pasteboard.data(forType: .rtf) { return ClipboardContent(kind: "rtf", data: rtf, plainText: text) }
        return text.map(ClipboardContent.text)
    }
    public func writeContent(_ content: ClipboardContent) throws {
        try content.validate();
        if content.kind == "text" {
            try writeText(String(decoding: content.data, as: UTF8.self));
            return
        }
        let pasteboard = NSPasteboard.general;
        pasteboard.clearContents()
        let type: NSPasteboard.PasteboardType =
            content.kind == "png" ? .png : content.kind == "url" ? .URL : content.kind == "html" ? .html : .rtf
        guard pasteboard.setData(content.data, forType: type) else { throw ClipboardError.unavailable }
        if let text = content.plainText { pasteboard.setString(text, forType: .string) };
        observed = pasteboard.changeCount
    }
    public func writeText(_ text: String) throws {
        let pasteboard = NSPasteboard.general;
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ClipboardError.unavailable }
        observed = pasteboard.changeCount
    }
    public func writeFiles(_ paths: [String], cut: Bool = false) throws {
        let pasteboard = NSPasteboard.general;
        pasteboard.clearContents()
        guard pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }) else {
            throw ClipboardError.unavailable
        }
        if cut { pasteboard.setString("1", forType: .init("com.sharemouse.cut")) };
        observed = pasteboard.changeCount
    }
    public func stop() {
        timer?.cancel();
        timer = nil
    }
}
