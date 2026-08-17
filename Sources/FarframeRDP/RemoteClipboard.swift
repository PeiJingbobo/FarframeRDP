import AppKit
import Foundation

enum ClipboardTextPolicy {
    static let maximumUTF8Bytes = 1024 * 1024

    static func acceptedText(_ text: String?) -> String? {
        guard let text, text.utf8.count <= maximumUTF8Bytes else {
            return nil
        }
        return text
    }
}

@MainActor
final class RemoteClipboardController: ObservableObject {
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var applyingRemoteText = false
    var onLocalTextChange: (@MainActor (String?) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        publishCurrentText()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onLocalTextChange = nil
    }

    func currentText() -> String? {
        ClipboardTextPolicy.acceptedText(pasteboard.string(forType: .string))
    }

    func applyRemoteText(_ text: String) {
        guard let accepted = ClipboardTextPolicy.acceptedText(text) else { return }
        applyingRemoteText = true
        pasteboard.clearContents()
        pasteboard.setString(accepted, forType: .string)
        lastChangeCount = pasteboard.changeCount
        applyingRemoteText = false
    }

    private func publishCurrentText() {
        onLocalTextChange?(currentText())
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !applyingRemoteText else { return }
        publishCurrentText()
    }
}
