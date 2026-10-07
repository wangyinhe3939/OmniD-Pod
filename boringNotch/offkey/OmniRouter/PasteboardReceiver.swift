import AppKit
import SwiftUI

enum RouterPasteboard {
    static func decode(_ pasteboard: NSPasteboard) -> (inputs: [RouterInput], promises: [NSFilePromiseReceiver]) {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let promises = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
        var inputs = [RouterInput]()
        var seenFiles = Set<URL>()
        for item in pasteboard.pasteboardItems ?? [] {
            if item.availableType(from: promiseTypes) != nil { continue }
            if let path = item.string(forType: .fileURL) {
                if let decoded = URL(string: path), let matched = fileURLs.first(where: { $0.standardizedFileURL == decoded.standardizedFileURL }),
                   seenFiles.insert(matched).inserted { inputs.append(RouterInput(value: .file(matched, owned: false), title: matched.lastPathComponent)) }
            } else if let web = item.string(forType: .URL) {
                inputs.append(RouterInput(value: .web(web), title: web))
            } else if let text = item.string(forType: .string) {
                inputs.append(RouterInput(value: .text(text), title: String(text.prefix(60))))
            }
        }
        return (inputs, promises)
    }
}

@MainActor
final class RouterTextView: NSTextView {
    var receive: @MainActor @Sendable ([RouterInput]) -> Void = { _ in }
    var failure: @MainActor @Sendable (String) -> Void = { _ in }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .URL, .string]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) })
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        textColor = .labelColor
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        textContainerInset = NSSize(width: 0, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        setAccessibilityLabel("待归档文字、网址或文件")
    }

    required init?(coder: NSCoder) { return nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { ingest(sender.draggingPasteboard) }

    override func paste(_ sender: Any?) {
        let decoded = RouterPasteboard.decode(.general)
        let containsFiles = decoded.inputs.contains { if case .file = $0.value { return true }; return false }
        if containsFiles || !decoded.promises.isEmpty || NSPasteboard.general.string(forType: .string) == nil {
            _ = ingest(.general)
        } else { super.paste(sender) }
    }

    private func ingest(_ pasteboard: NSPasteboard) -> Bool {
        let decoded = RouterPasteboard.decode(pasteboard)
        guard !decoded.inputs.isEmpty || !decoded.promises.isEmpty else {
            failure("未识别可接收的内容，原输入保留。"); return false
        }
        receive(decoded.inputs)
        if !decoded.promises.isEmpty {
            let destination = RouterAccess.support.appendingPathComponent("Promises", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            RouterPromiseReceiving.receive(decoded.promises, to: destination, queue: OmniRouterRuntime.shared.files,
                                           completion: receive, failed: failure)
        }
        return true
    }
}

@MainActor struct RouterInputEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.workspaceTextScale) private var scale
    let receive: @MainActor @Sendable ([RouterInput]) -> Void
    let failure: @MainActor @Sendable (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        init(_ binding: Binding<String>) { self.binding = binding }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { binding.wrappedValue = view.string }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = RouterTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.binding = $text
        guard let view = scroll.documentView as? RouterTextView else { return }
        view.receive = receive; view.failure = failure
        view.font = .systemFont(ofSize: 12 * scale)
        if !view.hasMarkedText(), view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }
}

@MainActor enum RouterPromiseReceiving {
    static func receive(_ receivers: [NSFilePromiseReceiver], to destination: URL, queue: OperationQueue,
                        completion: @escaping @MainActor @Sendable ([RouterInput]) -> Void,
                        failed: @escaping @MainActor @Sendable (String) -> Void) {
        let batch = RouterPromiseBatch(receivers)
        let locations = receivers.indices.map { destination.appendingPathComponent(String($0), isDirectory: true) }
        queue.addOperation {
            do { for location in locations { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) } }
            catch { DispatchQueue.main.async { failed("文件承诺暂存失败：" + RouterFailure.message(for: error)) }; return }
            DispatchQueue.main.async {
                for (receiver, location) in zip(batch.receivers, locations) {
                    receiver.receivePromisedFiles(atDestination: location, options: [:], operationQueue: queue) { url, error in
                        let contained = RouterAccess.inside(url.resolvingSymlinksInPath(), location.resolvingSymlinksInPath())
                        withExtendedLifetime(batch) {
                            DispatchQueue.main.async {
                                if let error = error { failed("文件承诺失败：" + RouterFailure.message(for: error)) }
                                else if !contained { failed("文件承诺回调越出收件目录，未接管该文件。") }
                                else { completion([RouterInput(value: .file(url, owned: true), title: url.lastPathComponent)]) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@MainActor private final class RouterPromiseBatch {
    let receivers: [NSFilePromiseReceiver]
    init(_ receivers: [NSFilePromiseReceiver]) { self.receivers = receivers }
}
