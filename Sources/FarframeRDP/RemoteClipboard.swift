import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum ClipboardTransferPolicy {
    static let maximumTextBytes = 1024 * 1024
    static let maximumRichTextBytes = 8 * 1024 * 1024
    static let maximumImageBytes = 32 * 1024 * 1024
    static let maximumImageDimension = 16_384
    static let maximumImagePixels = 100_000_000
}

enum ClipboardTextPolicy {
    static let maximumUTF8Bytes = ClipboardTransferPolicy.maximumTextBytes

    static func acceptedText(_ text: String?) -> String? {
        guard let text, text.utf8.count <= maximumUTF8Bytes else {
            return nil
        }
        return text
    }

    static func encodeWireText(_ text: String) -> Data? {
        guard let accepted = acceptedText(text) else { return nil }
        var data = Data(capacity: (accepted.utf16.count + 1) * 2)
        for codeUnit in accepted.utf16 {
            var value = codeUnit.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [0, 0])
        return data
    }

    static func decodeWireText(_ data: Data) -> String? {
        guard data.count >= 2,
              data.count <= maximumUTF8Bytes * 2 + 2,
              data.count.isMultiple(of: 2),
              data.suffix(2) == Data([0, 0]) else {
            return nil
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(data.count / 2 - 1)
        for index in stride(from: 0, to: data.count - 2, by: 2) {
            codeUnits.append(UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
        }
        return acceptedText(String(decoding: codeUnits, as: UTF16.self))
    }
}

struct ClipboardPayloadSet: Equatable, Sendable {
    private(set) var representations: [ClipboardContentKind: Data] = [:]
    var localFiles: [ClipboardLocalFileSnapshot] = []

    var isEmpty: Bool { representations.isEmpty }

    subscript(kind: ClipboardContentKind) -> Data? {
        get { representations[kind] }
        set { representations[kind] = newValue }
    }

    var kinds: Set<ClipboardContentKind> {
        Set(representations.keys)
    }
}

struct ClipboardLocalFileSnapshot: Equatable, Sendable {
    let url: URL
    let name: String
    let size: UInt64
    let modificationDate: Date
    let deviceID: UInt64
    let inode: UInt64
}

struct ClipboardRemoteFileDescriptor: Equatable, Sendable {
    let name: String
    let size: UInt64
    let modificationDate: Date?
}

enum ClipboardFilePolicy {
    static let maximumFileCount = 100
    static let maximumSingleFileBytes: UInt64 = 2 * 1024 * 1024 * 1024 - 1
    static let maximumBatchBytes: UInt64 = 4 * 1024 * 1024 * 1024
    static let descriptorSize = 592
    static let maximumNameUTF16Units = 259

    static func acceptedName(_ value: String) -> String? {
        let name = value.precomposedStringWithCanonicalMapping
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf16.count <= maximumNameUTF16Units,
              !name.hasSuffix("."),
              !name.hasSuffix(" "),
              !name.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0 == "/" || $0 == "\\" || $0.value == 0
              }) else {
            return nil
        }
        let stem = name.split(separator: ".", maxSplits: 1).first?.uppercased() ?? ""
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] +
            (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        return reserved.contains(stem) ? nil : name
    }
}

enum ClipboardFileListCodec {
    private static let filetimeEpochOffset: TimeInterval = 11_644_473_600

    static func encode(_ files: [ClipboardLocalFileSnapshot]) -> Data? {
        guard !files.isEmpty, files.count <= ClipboardFilePolicy.maximumFileCount else {
            return nil
        }
        var total: UInt64 = 0
        var names = Set<String>()
        for file in files {
            guard file.size <= ClipboardFilePolicy.maximumSingleFileBytes,
                  let name = ClipboardFilePolicy.acceptedName(file.name),
                  names.insert(name.lowercased()).inserted,
                  UInt64.max - total >= file.size else {
                return nil
            }
            total += file.size
            guard total <= ClipboardFilePolicy.maximumBatchBytes else { return nil }
        }
        var data = Data(count: 4 + files.count * ClipboardFilePolicy.descriptorSize)
        data.writeUInt32(UInt32(files.count), at: 0)
        for (index, file) in files.enumerated() {
            let base = 4 + index * ClipboardFilePolicy.descriptorSize
            data.writeUInt32(0x64, at: base) // attributes, write time and size
            data.writeUInt32(0x80, at: base + 36) // FILE_ATTRIBUTE_NORMAL
            let filetime = UInt64(max(
                0,
                (file.modificationDate.timeIntervalSince1970 + filetimeEpochOffset) * 10_000_000
            ))
            data.writeUInt64(filetime, at: base + 56)
            data.writeUInt32(UInt32(file.size >> 32), at: base + 64)
            data.writeUInt32(UInt32(truncatingIfNeeded: file.size), at: base + 68)
            var nameOffset = base + 72
            for codeUnit in file.name.precomposedStringWithCanonicalMapping.utf16 {
                data.writeUInt16(codeUnit, at: nameOffset)
                nameOffset += 2
            }
            data.writeUInt16(0, at: nameOffset)
        }
        return data
    }

    static func decode(_ data: Data) -> [ClipboardRemoteFileDescriptor]? {
        guard let countValue = data.uint32(at: 0),
              countValue > 0,
              countValue <= ClipboardFilePolicy.maximumFileCount else {
            return nil
        }
        let count = Int(countValue)
        guard data.count == 4 + count * ClipboardFilePolicy.descriptorSize else { return nil }
        var result: [ClipboardRemoteFileDescriptor] = []
        var total: UInt64 = 0
        var names = Set<String>()
        for index in 0..<count {
            let base = 4 + index * ClipboardFilePolicy.descriptorSize
            guard let flags = data.uint32(at: base), flags & 0x40 != 0,
                  let attributes = data.uint32(at: base + 36),
                  attributes & 0x10 == 0,
                  attributes & 0x400 == 0,
                  let high = data.uint32(at: base + 64),
                  let low = data.uint32(at: base + 68) else {
                return nil
            }
            let size = (UInt64(high) << 32) | UInt64(low)
            guard size <= ClipboardFilePolicy.maximumSingleFileBytes,
                  UInt64.max - total >= size else { return nil }
            total += size
            guard total <= ClipboardFilePolicy.maximumBatchBytes else { return nil }
            var nameUnits: [UInt16] = []
            for unitIndex in 0..<260 {
                guard let unit = data.uint16(at: base + 72 + unitIndex * 2) else { return nil }
                if unit == 0 { break }
                nameUnits.append(unit)
            }
            guard nameUnits.count < 260,
                  validUTF16(nameUnits),
                  let name = ClipboardFilePolicy.acceptedName(
                      String(decoding: nameUnits, as: UTF16.self)
                  ),
                  names.insert(name.lowercased()).inserted else {
                return nil
            }
            var modificationDate: Date?
            if flags & 0x20 != 0, let filetime = data.uint64(at: base + 56), filetime > 0 {
                let seconds = TimeInterval(filetime) / 10_000_000 - filetimeEpochOffset
                modificationDate = Date(timeIntervalSince1970: seconds)
            }
            result.append(ClipboardRemoteFileDescriptor(
                name: name,
                size: size,
                modificationDate: modificationDate
            ))
        }
        return result
    }

    private static func validUTF16(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count,
                      (0xDC00...0xDFFF).contains(units[index + 1]) else { return false }
                index += 2
            } else if (0xDC00...0xDFFF).contains(unit) {
                return false
            } else {
                index += 1
            }
        }
        return true
    }
}

enum ClipboardHTMLCodec {
    private static let startMarker = Data("<!--StartFragment-->".utf8)
    private static let endMarker = Data("<!--EndFragment-->".utf8)
    private static let documentPrefix = Data("<html><body><!--StartFragment-->".utf8)
    private static let documentSuffix = Data("<!--EndFragment--></body></html>".utf8)

    static func encode(fragment: Data) -> Data? {
        guard !fragment.isEmpty,
              fragment.count <= ClipboardTransferPolicy.maximumRichTextBytes,
              String(data: fragment, encoding: .utf8) != nil else {
            return nil
        }
        let template = "Version:1.0\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n"
        let placeholderHeader = String(format: template, 0, 0, 0, 0)
        let startHTML = placeholderHeader.utf8.count
        let startFragment = startHTML + documentPrefix.count
        let endFragment = startFragment + fragment.count
        let endHTML = endFragment + documentSuffix.count
        guard endHTML <= ClipboardTransferPolicy.maximumRichTextBytes else { return nil }
        let header = String(format: template, startHTML, endHTML, startFragment, endFragment)
        var result = Data(header.utf8)
        result.append(documentPrefix)
        result.append(fragment)
        result.append(documentSuffix)
        return result
    }

    static func decode(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= ClipboardTransferPolicy.maximumRichTextBytes else {
            return nil
        }
        if let offsets = offsets(in: data),
           offsets.startHTML <= offsets.startFragment,
           offsets.startFragment <= offsets.endFragment,
           offsets.endFragment <= offsets.endHTML,
           offsets.endHTML <= data.count {
            let fragment = data.subdata(in: offsets.startFragment..<offsets.endFragment)
            return String(data: fragment, encoding: .utf8) == nil ? nil : fragment
        }
        guard let start = data.range(of: startMarker)?.upperBound,
              let end = data.range(of: endMarker, in: start..<data.endIndex)?.lowerBound,
              start <= end else {
            return nil
        }
        let fragment = data.subdata(in: start..<end)
        return String(data: fragment, encoding: .utf8) == nil ? nil : fragment
    }

    private static func offsets(in data: Data) -> (
        startHTML: Int,
        endHTML: Int,
        startFragment: Int,
        endFragment: Int
    )? {
        let prefix = data.prefix(min(data.count, 4096))
        guard let header = String(data: prefix, encoding: .ascii) else { return nil }
        func value(_ name: String) -> Int? {
            guard let range = header.range(of: name + ":") else { return nil }
            let tail = header[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
        guard let startHTML = value("StartHTML"),
              let endHTML = value("EndHTML"),
              let startFragment = value("StartFragment"),
              let endFragment = value("EndFragment") else {
            return nil
        }
        return (startHTML, endHTML, startFragment, endFragment)
    }
}

struct ClipboardDecodedImage: Sendable {
    let png: Data
    let tiff: Data?
}

enum ClipboardPNGCodec {
    static func encode(imageData: Data) -> ClipboardDecodedImage? {
        prepare(imageData, requirePNG: false)
    }

    static func decode(_ data: Data) -> ClipboardDecodedImage? {
        prepare(data, requirePNG: true)
    }

    private static func prepare(_ data: Data, requirePNG: Bool) -> ClipboardDecodedImage? {
        guard !data.isEmpty,
              data.count <= ClipboardTransferPolicy.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              (!requirePNG || CGImageSourceGetType(source) as String? == "public.png"),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              image.width <= ClipboardTransferPolicy.maximumImageDimension,
              image.height <= ClipboardTransferPolicy.maximumImageDimension,
              image.width * image.height <= ClipboardTransferPolicy.maximumImagePixels else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]),
              png.count <= ClipboardTransferPolicy.maximumImageBytes else {
            return nil
        }
        let tiff = representation.tiffRepresentation.flatMap {
            $0.count <= ClipboardTransferPolicy.maximumImageBytes ? $0 : nil
        }
        return ClipboardDecodedImage(png: png, tiff: tiff)
    }
}

enum ClipboardDIBCodec {
    private static let bitmapInfoHeaderSize = 40
    private static let bitmapV5HeaderSize = 124

    static func encodeV5(imageData: Data) -> Data? {
        guard let pixels = canonicalPixels(from: imageData) else { return nil }
        var result = Data(count: bitmapV5HeaderSize)
        result.writeUInt32(UInt32(bitmapV5HeaderSize), at: 0)
        result.writeInt32(Int32(pixels.width), at: 4)
        result.writeInt32(-Int32(pixels.height), at: 8)
        result.writeUInt16(1, at: 12)
        result.writeUInt16(32, at: 14)
        result.writeUInt32(3, at: 16)
        result.writeUInt32(UInt32(pixels.data.count), at: 20)
        result.writeInt32(3_780, at: 24)
        result.writeInt32(3_780, at: 28)
        result.writeUInt32(0x00FF_0000, at: 40)
        result.writeUInt32(0x0000_FF00, at: 44)
        result.writeUInt32(0x0000_00FF, at: 48)
        result.writeUInt32(0xFF00_0000, at: 52)
        result.writeUInt32(0x7352_4742, at: 56) // LCS_sRGB
        result.writeUInt32(4, at: 108) // LCS_GM_IMAGES
        result.append(pixels.data)
        return result.count <= ClipboardTransferPolicy.maximumImageBytes ? result : nil
    }

    static func encodeDIB(imageData: Data) -> Data? {
        guard let pixels = canonicalPixels(from: imageData) else { return nil }
        var result = Data(count: bitmapInfoHeaderSize)
        result.writeUInt32(UInt32(bitmapInfoHeaderSize), at: 0)
        result.writeInt32(Int32(pixels.width), at: 4)
        result.writeInt32(-Int32(pixels.height), at: 8)
        result.writeUInt16(1, at: 12)
        result.writeUInt16(32, at: 14)
        result.writeUInt32(0, at: 16) // BI_RGB; alpha is not guaranteed.
        result.writeUInt32(UInt32(pixels.data.count), at: 20)
        var opaquePixels = pixels.data
        for index in stride(from: 3, to: opaquePixels.count, by: 4) {
            opaquePixels[index] = 255
        }
        result.append(opaquePixels)
        return result.count <= ClipboardTransferPolicy.maximumImageBytes ? result : nil
    }

    static func decode(_ data: Data) -> ClipboardDecodedImage? {
        guard data.count >= bitmapInfoHeaderSize,
              data.count <= ClipboardTransferPolicy.maximumImageBytes else {
            return nil
        }
        guard let headerSize = data.uint32(at: 0).flatMap(Int.init),
              headerSize >= bitmapInfoHeaderSize,
              headerSize <= data.count,
              let signedWidth = data.int32(at: 4),
              let signedHeight = data.int32(at: 8),
              signedWidth > 0,
              signedHeight != 0,
              signedHeight != Int32.min,
              data.uint16(at: 12) == 1,
              let bitsPerPixel = data.uint16(at: 14),
              bitsPerPixel == 24 || bitsPerPixel == 32,
              let compression = data.uint32(at: 16),
              compression == 0 || compression == 3 else {
            return nil
        }
        let width = Int(signedWidth)
        let height = Int(abs(signedHeight))
        guard validDimensions(width: width, height: height) else { return nil }
        let bitsPerRow = width.multipliedReportingOverflow(by: Int(bitsPerPixel))
        guard !bitsPerRow.overflow else { return nil }
        let sourceBytesPerRow = ((bitsPerRow.partialValue + 31) / 32) * 4
        let sourceLength = sourceBytesPerRow.multipliedReportingOverflow(by: height)
        guard !sourceLength.overflow else { return nil }
        var pixelOffset = headerSize
        if headerSize == bitmapInfoHeaderSize, compression == 3 {
            pixelOffset += 12
        }
        guard pixelOffset <= data.count,
              sourceLength.partialValue <= data.count - pixelOffset else {
            return nil
        }
        var destination = Data(count: width * height * 4)
        let topDown = signedHeight < 0
        destination.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                guard let targetBase = target.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }
                for y in 0..<height {
                    let sourceY = topDown ? y : height - y - 1
                    let sourceRow = sourceBase + pixelOffset + sourceY * sourceBytesPerRow
                    let targetRow = targetBase + y * width * 4
                    for x in 0..<width {
                        let sourcePixel = sourceRow + x * Int(bitsPerPixel / 8)
                        let targetPixel = targetRow + x * 4
                        targetPixel[0] = sourcePixel[0]
                        targetPixel[1] = sourcePixel[1]
                        targetPixel[2] = sourcePixel[2]
                        targetPixel[3] = bitsPerPixel == 32 && compression == 3
                            ? sourcePixel[3]
                            : 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: destination as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]),
              png.count <= ClipboardTransferPolicy.maximumImageBytes else {
            return nil
        }
        let tiff = representation.tiffRepresentation.flatMap {
            $0.count <= ClipboardTransferPolicy.maximumImageBytes ? $0 : nil
        }
        return ClipboardDecodedImage(png: png, tiff: tiff)
    }

    private static func canonicalPixels(from data: Data) -> (width: Int, height: Int, data: Data)? {
        guard !data.isEmpty,
              data.count <= ClipboardTransferPolicy.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard validDimensions(width: width, height: height) else { return nil }
        let byteCount = width * height * 4
        var pixels = Data(count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                          CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? (width, height, pixels) : nil
    }

    private static func validDimensions(width: Int, height: Int) -> Bool {
        guard width > 0,
              height > 0,
              width <= ClipboardTransferPolicy.maximumImageDimension,
              height <= ClipboardTransferPolicy.maximumImageDimension else {
            return false
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        return !pixels.overflow && pixels.partialValue <= ClipboardTransferPolicy.maximumImagePixels
    }
}

private final class RemoteClipboardFileDataProvider: NSObject, NSPasteboardItemDataProvider,
    @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var items: [ObjectIdentifier: URL] = [:]

    init(generation: UInt64) {
        self.generation = generation
    }

    func register(_ item: NSPasteboardItem, url: URL) {
        lock.withLock {
            items[ObjectIdentifier(item)] = url
        }
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL else { return }
        if let url = lock.withLock({ items[ObjectIdentifier(item)] }) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        // Supplying every placeholder URL only means Finder finished inspecting
        // the pasteboard. Clipboard ownership is tracked by changeCount instead.
    }
}

private final class RemoteClipboardFilePresenter: NSObject, NSFilePresenter,
    @unchecked Sendable {
    typealias Reader = @Sendable ((@Sendable () -> Void)?) -> Void

    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onRead: @Sendable (@escaping Reader) -> Void

    init(
        url: URL,
        onRead: @escaping @Sendable (@escaping Reader) -> Void
    ) {
        presentedItemURL = url
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.name = "Farframe remote clipboard file presenter"
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        self.onRead = onRead
    }

    func relinquishPresentedItem(
        toReader reader: @escaping Reader
    ) {
        onRead(reader)
    }
}

private final class RemoteClipboardFileMaterializer: @unchecked Sendable {
    typealias Reader = RemoteClipboardFilePresenter.Reader

    let generation: UInt64
    let directory: URL
    let urls: [URL]
    private let onRequest: @MainActor (UInt64, URL) -> Void
    private let lock = NSLock()
    private var readers: [Reader] = []
    private var requested = false
    private var completed = false
    private var cancelled = false
    private var presenters: [RemoteClipboardFilePresenter] = []

    var isComplete: Bool {
        lock.withLock { completed }
    }

    init(
        generation: UInt64,
        directory: URL,
        urls: [URL],
        onRequest: @escaping @MainActor (UInt64, URL) -> Void
    ) {
        self.generation = generation
        self.directory = directory
        self.urls = urls
        self.onRequest = onRequest
        presenters = urls.map { url in
            RemoteClipboardFilePresenter(url: url) { [weak self] reader in
                self?.requestRead(reader)
            }
        }
        presenters.forEach(NSFileCoordinator.addFilePresenter)
    }

    deinit {
        presenters.forEach(NSFileCoordinator.removeFilePresenter)
    }

    func finish(success: Bool) {
        let pending: [Reader] = lock.withLock {
            guard !completed, !cancelled else { return [] }
            completed = success
            cancelled = !success
            let pending = readers
            readers.removeAll()
            return pending
        }
        pending.forEach { $0(nil) }
    }

    func cancel() {
        let pending: [Reader] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            let pending = readers
            readers.removeAll()
            return pending
        }
        pending.forEach { $0(nil) }
    }

    private func requestRead(_ reader: @escaping Reader) {
        let action: (releaseImmediately: Bool, beginRequest: Bool) = lock.withLock {
            if completed || cancelled {
                return (true, false)
            }
            readers.append(reader)
            guard !requested else { return (false, false) }
            requested = true
            return (false, true)
        }
        if action.releaseImmediately {
            reader(nil)
        } else if action.beginRequest {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onRequest(self.generation, self.directory)
            }
        }
    }
}

@MainActor
final class RemoteClipboardController: ObservableObject {
    private struct PasteboardSnapshot: Sendable {
        let fileURLs: [URL]
        let text: String?
        let html: Data?
        let rtf: Data?
        let image: Data?
    }

    private struct PreparedRemoteContent: Sendable {
        let text: String?
        let html: Data?
        let rtf: Data?
        let image: ClipboardDecodedImage?
    }

    private struct DirectSaveTransfer: @unchecked Sendable {
        let generation: UInt64
        let stagingDirectory: URL
        let stagingURLs: [URL]
        let targetURLs: [URL]
        let allowsReplacingTarget: Bool
        let onCancel: @MainActor (UInt64) -> Void
        let onCompletion: @MainActor (Bool, [URL]) -> Void
    }

    private static let pngType = NSPasteboard.PasteboardType("public.png")
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")

    private let pasteboard: NSPasteboard
    private let notificationCenter: NotificationCenter
    private let deferRemoteFileOffersWhileApplicationActive: Bool
    private let isApplicationActive: @MainActor () -> Bool
    private var timer: Timer?
    private var applicationResignObserver: NSObjectProtocol?
    private var lastChangeCount: Int
    private var applyingRemoteContent = false
    private var ownedRemoteFileDirectory: URL?
    private var remoteFileProvider: RemoteClipboardFileDataProvider?
    private var remoteFileMaterializer: RemoteClipboardFileMaterializer?
    private var remoteFileItems: [NSPasteboardItem] = []
    private var remoteFileOfferPublished = false
    private var onRemoteFilePromiseCancelled: (@MainActor (UInt64) -> Void)?
    private var directSaveTransfer: DirectSaveTransfer?
    private var contentRevision: UInt64 = 0
    private var latestContent = ClipboardPayloadSet()
    var onLocalContentChange: (@MainActor (ClipboardPayloadSet) -> Void)?

    init(
        pasteboard: NSPasteboard = .general,
        notificationCenter: NotificationCenter = .default,
        deferRemoteFileOffersWhileApplicationActive: Bool = true,
        isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        self.pasteboard = pasteboard
        self.notificationCenter = notificationCenter
        self.deferRemoteFileOffersWhileApplicationActive =
            deferRemoteFileOffersWhileApplicationActive
        self.isApplicationActive = isApplicationActive
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        applicationResignObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publishDeferredRemoteFileOffer() }
        }
        publishCurrentContent()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let applicationResignObserver {
            notificationCenter.removeObserver(applicationResignObserver)
            self.applicationResignObserver = nil
        }
        contentRevision &+= 1
        let hadPublishedUnfulfilledPromise = remoteFileOfferPublished &&
            remoteFileMaterializer?.isComplete == false
        discardRemoteFilePromise(notifyCancellation: true)
        discardDirectSaveTransfer(notifyCancellation: true)
        removeOwnedRemoteFiles()
        if hadPublishedUnfulfilledPromise {
            applyingRemoteContent = true
            pasteboard.clearContents()
            lastChangeCount = pasteboard.changeCount
            applyingRemoteContent = false
        }
        onLocalContentChange = nil
    }

    func currentContent() -> ClipboardPayloadSet {
        latestContent
    }

    private func capturePasteboard() -> PasteboardSnapshot {
        let fileURLs: [URL] = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL])?.compactMap { value in
            guard let path = value.path, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } ?? []
        return PasteboardSnapshot(
            fileURLs: fileURLs,
            text: pasteboard.string(forType: .string),
            html: pasteboard.data(forType: .html),
            rtf: pasteboard.data(forType: .rtf),
            image: pasteboard.data(forType: Self.pngType) ??
                pasteboard.data(forType: .tiff) ??
                pasteboard.data(forType: Self.jpegType)
        )
    }

    nonisolated private static func buildContent(
        from snapshot: PasteboardSnapshot
    ) -> ClipboardPayloadSet {
        var payloads = ClipboardPayloadSet()
        if !snapshot.fileURLs.isEmpty {
            let snapshots = snapshot.fileURLs.compactMap(localFileSnapshot)
            guard snapshots.count == snapshot.fileURLs.count,
                  let list = ClipboardFileListCodec.encode(snapshots) else {
                return payloads
            }
            payloads.localFiles = snapshots
            payloads[.fileList] = list
            return payloads
        }
        if let text = ClipboardTextPolicy.acceptedText(snapshot.text) {
            payloads[.unicodeText] = ClipboardTextPolicy.encodeWireText(text)
        }
        if let html = snapshot.html,
           html.count <= ClipboardTransferPolicy.maximumRichTextBytes {
            payloads[.html] = ClipboardHTMLCodec.encode(fragment: html)
        }
        if let rtf = snapshot.rtf,
           !rtf.isEmpty,
           rtf.count <= ClipboardTransferPolicy.maximumRichTextBytes {
            payloads[.rtf] = rtf
        }
        if let imageData = snapshot.image {
            payloads[.png] = ClipboardPNGCodec.encode(imageData: imageData)?.png
            payloads[.dibV5] = ClipboardDIBCodec.encodeV5(imageData: imageData)
            payloads[.dib] = ClipboardDIBCodec.encodeDIB(imageData: imageData)
        }
        return payloads
    }

    nonisolated private static func localFileSnapshot(_ url: URL) -> ClipboardLocalFileSnapshot? {
        guard url.isFileURL,
              !url.path.isEmpty,
              (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let sizeNumber = attributes[.size] as? NSNumber,
              let deviceNumber = attributes[.systemNumber] as? NSNumber,
              let inodeNumber = attributes[.systemFileNumber] as? NSNumber,
              let name = ClipboardFilePolicy.acceptedName(url.lastPathComponent) else {
            return nil
        }
        let size = sizeNumber.uint64Value
        guard size <= ClipboardFilePolicy.maximumSingleFileBytes else { return nil }
        return ClipboardLocalFileSnapshot(
            url: url,
            name: name,
            size: size,
            modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
            deviceID: deviceNumber.uint64Value,
            inode: inodeNumber.uint64Value
        )
    }

    func applyRemoteContent(_ payloads: ClipboardPayloadSet) {
        contentRevision &+= 1
        let revision = contentRevision
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared = Self.prepareRemoteContent(payloads)
            Task { @MainActor [weak self] in
                guard let self, self.contentRevision == revision else { return }
                self.commitRemoteContent(prepared, original: payloads)
            }
        }
    }

    nonisolated private static func prepareRemoteContent(
        _ payloads: ClipboardPayloadSet
    ) -> PreparedRemoteContent {
        PreparedRemoteContent(
            text: payloads[.unicodeText].flatMap(ClipboardTextPolicy.decodeWireText),
            html: payloads[.html].flatMap(ClipboardHTMLCodec.decode),
            rtf: payloads[.rtf].flatMap { data in
                !data.isEmpty && data.count <= ClipboardTransferPolicy.maximumRichTextBytes
                    ? data : nil
            },
            image: payloads[.png].flatMap(ClipboardPNGCodec.decode) ??
                payloads[.dibV5].flatMap(ClipboardDIBCodec.decode) ??
                payloads[.dib].flatMap(ClipboardDIBCodec.decode)
        )
    }

    private func commitRemoteContent(
        _ prepared: PreparedRemoteContent,
        original payloads: ClipboardPayloadSet
    ) {
        let item = NSPasteboardItem()
        var hasRepresentation = false
        if let text = prepared.text {
            item.setString(text, forType: .string)
            hasRepresentation = true
        }
        if let fragment = prepared.html {
            item.setData(fragment, forType: .html)
            hasRepresentation = true
        }
        if let rtf = prepared.rtf {
            item.setData(rtf, forType: .rtf)
            hasRepresentation = true
        }
        if let decodedImage = prepared.image {
            item.setData(decodedImage.png, forType: Self.pngType)
            if let tiff = decodedImage.tiff {
                item.setData(tiff, forType: .tiff)
            }
            hasRepresentation = true
        }
        guard hasRepresentation else { return }
        discardRemoteFilePromise(notifyCancellation: true)
        applyingRemoteContent = true
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
        latestContent = payloads
        applyingRemoteContent = false
    }

    func applyRemoteFiles(_ urls: [URL]) {
        guard !urls.isEmpty,
              urls.allSatisfy(\.isFileURL),
              let directory = urls.first?.deletingLastPathComponent(),
              urls.allSatisfy({ $0.deletingLastPathComponent() == directory }) else {
            return
        }
        discardRemoteFilePromise(notifyCancellation: true)
        removeOwnedRemoteFiles()
        contentRevision &+= 1
        applyingRemoteContent = true
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            applyingRemoteContent = false
            try? FileManager.default.removeItem(at: directory)
            return
        }
        ownedRemoteFileDirectory = directory
        lastChangeCount = pasteboard.changeCount
        applyingRemoteContent = false
    }

    @discardableResult
    func offerRemoteFiles(
        generation: UInt64,
        files: [ClipboardRemoteFileDescriptor],
        onRequest: @escaping @MainActor (UInt64, URL) -> Void,
        onCancel: @escaping @MainActor (UInt64) -> Void
    ) -> Bool {
        guard generation != 0,
              !files.isEmpty,
              files.count <= ClipboardFilePolicy.maximumFileCount,
              files.allSatisfy({ ClipboardFilePolicy.acceptedName($0.name) != nil }),
              let prepared = Self.prepareRemoteFilePlaceholders(files: files) else {
            return false
        }
        discardRemoteFilePromise(notifyCancellation: true)
        discardDirectSaveTransfer(notifyCancellation: true)
        removeOwnedRemoteFiles()
        contentRevision &+= 1

        let provider = RemoteClipboardFileDataProvider(generation: generation)
        let items = prepared.urls.map { url in
            let item = NSPasteboardItem()
            provider.register(item, url: url)
            item.setDataProvider(provider, forTypes: [.fileURL])
            return item
        }
        let materializer = RemoteClipboardFileMaterializer(
            generation: generation,
            directory: prepared.directory,
            urls: prepared.urls,
            onRequest: onRequest
        )

        remoteFileProvider = provider
        remoteFileMaterializer = materializer
        remoteFileItems = items
        ownedRemoteFileDirectory = prepared.directory
        onRemoteFilePromiseCancelled = onCancel
        if deferRemoteFileOffersWhileApplicationActive && isApplicationActive() {
            return true
        }
        return publishDeferredRemoteFileOffer()
    }

    @discardableResult
    func saveRemoteFiles(
        generation: UInt64,
        files: [ClipboardRemoteFileDescriptor],
        destination: ClipboardDirectSaveDestination,
        onRequest: @escaping @MainActor (UInt64, URL) -> Void,
        onCancel: @escaping @MainActor (UInt64) -> Void,
        onCompletion: @escaping @MainActor (Bool, [URL]) -> Void
    ) -> Bool {
        guard generation != 0,
              !files.isEmpty,
              files.count <= ClipboardFilePolicy.maximumFileCount,
              files.allSatisfy({ ClipboardFilePolicy.acceptedName($0.name) != nil }),
              let targets = Self.directSaveTargets(for: files, destination: destination),
              let prepared = Self.prepareRemoteFilePlaceholders(files: files) else {
            return false
        }
        discardRemoteFilePromise(notifyCancellation: true)
        discardDirectSaveTransfer(notifyCancellation: true)
        directSaveTransfer = DirectSaveTransfer(
            generation: generation,
            stagingDirectory: prepared.directory,
            stagingURLs: prepared.urls,
            targetURLs: targets.urls,
            allowsReplacingTarget: targets.allowsReplacingTarget,
            onCancel: onCancel,
            onCompletion: onCompletion
        )
        onRequest(generation, prepared.directory)
        return true
    }

    @discardableResult
    private func publishDeferredRemoteFileOffer() -> Bool {
        guard remoteFileProvider != nil else { return false }
        guard !remoteFileOfferPublished else { return true }
        applyingRemoteContent = true
        pasteboard.clearContents()
        guard pasteboard.writeObjects(remoteFileItems) else {
            applyingRemoteContent = false
            discardRemoteFilePromise(notifyCancellation: true)
            removeOwnedRemoteFiles()
            return false
        }
        remoteFileOfferPublished = true
        lastChangeCount = pasteboard.changeCount
        applyingRemoteContent = false
        return true
    }

    @discardableResult
    func fulfillRemoteFiles(generation: UInt64, urls: [URL]) -> Bool {
        if let materializer = remoteFileMaterializer,
           materializer.generation == generation,
           urls == materializer.urls {
            materializer.finish(success: true)
            onRemoteFilePromiseCancelled = nil
            return true
        }
        guard let transfer = directSaveTransfer,
              transfer.generation == generation,
              urls == transfer.stagingURLs else { return false }
        directSaveTransfer = nil
        Task.detached(priority: .userInitiated) {
            let installed = Self.installDirectSaveTransfer(transfer)
            await MainActor.run {
                transfer.onCompletion(installed, installed ? transfer.targetURLs : [])
            }
        }
        return true
    }

    func cancelRemoteFileOffer(generation: UInt64) {
        if remoteFileProvider?.generation == generation {
            let wasPublished = remoteFileOfferPublished
            discardRemoteFilePromise(notifyCancellation: false)
            removeOwnedRemoteFiles()
            if wasPublished {
                applyingRemoteContent = true
                pasteboard.clearContents()
                lastChangeCount = pasteboard.changeCount
                applyingRemoteContent = false
            }
        }
        if directSaveTransfer?.generation == generation {
            discardDirectSaveTransfer(notifyCancellation: false)
        }
    }

    private func publishCurrentContent() {
        contentRevision &+= 1
        let revision = contentRevision
        let snapshot = capturePasteboard()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let content = Self.buildContent(from: snapshot)
            Task { @MainActor [weak self] in
                guard let self, self.contentRevision == revision else { return }
                self.latestContent = content
                self.onLocalContentChange?(content)
            }
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !applyingRemoteContent else { return }
        discardRemoteFilePromise(notifyCancellation: true)
        removeOwnedRemoteFiles()
        publishCurrentContent()
    }

    private func discardRemoteFilePromise(notifyCancellation: Bool) {
        guard let provider = remoteFileProvider else { return }
        remoteFileProvider = nil
        let materializer = remoteFileMaterializer
        remoteFileMaterializer = nil
        remoteFileItems = []
        remoteFileOfferPublished = false
        removeOwnedRemoteFiles()
        materializer?.cancel()
        let cancellation = onRemoteFilePromiseCancelled
        onRemoteFilePromiseCancelled = nil
        if notifyCancellation, materializer?.isComplete == false {
            cancellation?(provider.generation)
        }
    }

    private func discardDirectSaveTransfer(notifyCancellation: Bool) {
        guard let transfer = directSaveTransfer else { return }
        directSaveTransfer = nil
        try? FileManager.default.removeItem(at: transfer.stagingDirectory)
        if notifyCancellation {
            transfer.onCancel(transfer.generation)
        }
    }

    private static func directSaveTargets(
        for files: [ClipboardRemoteFileDescriptor],
        destination: ClipboardDirectSaveDestination
    ) -> (urls: [URL], allowsReplacingTarget: Bool)? {
        let manager = FileManager.default
        switch destination {
        case let .file(url):
            guard files.count == 1,
                  url.isFileURL,
                  acceptedDirectSaveDirectory(url.deletingLastPathComponent()),
                  ClipboardFilePolicy.acceptedName(url.lastPathComponent) != nil else {
                return nil
            }
            var status = stat()
            if lstat(url.path, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFREG,
                      status.st_mode & S_IFMT != S_IFLNK else { return nil }
            } else if errno != ENOENT {
                return nil
            }
            return ([url.standardizedFileURL], true)
        case let .directory(directory):
            guard acceptedDirectSaveDirectory(directory) else { return nil }
            let standardized = directory.standardizedFileURL
            let urls = files.map {
                standardized.appendingPathComponent($0.name, isDirectory: false)
            }
            guard Set(urls).count == urls.count,
                  urls.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else {
                return nil
            }
            return (urls, false)
        }
    }

    nonisolated private static func acceptedDirectSaveDirectory(_ directory: URL) -> Bool {
        guard directory.isFileURL else { return false }
        var status = stat()
        return lstat(directory.standardizedFileURL.path, &status) == 0 &&
            status.st_mode & S_IFMT == S_IFDIR &&
            status.st_mode & S_IFMT != S_IFLNK
    }

    nonisolated private static func installDirectSaveTransfer(
        _ transfer: DirectSaveTransfer
    ) -> Bool {
        let manager = FileManager.default
        guard transfer.stagingURLs.count == transfer.targetURLs.count,
              transfer.targetURLs.allSatisfy({
                  acceptedDirectSaveDirectory($0.deletingLastPathComponent())
              }) else {
            try? manager.removeItem(at: transfer.stagingDirectory)
            return false
        }
        if !transfer.allowsReplacingTarget,
           transfer.targetURLs.contains(where: { manager.fileExists(atPath: $0.path) }) {
            try? manager.removeItem(at: transfer.stagingDirectory)
            return false
        }

        var destinationStagingURLs: [URL] = []
        var installedTargets: [URL] = []
        do {
            for (index, pair) in zip(transfer.stagingURLs, transfer.targetURLs).enumerated() {
                let (source, target) = pair
                let destinationStagingURL = target.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".farframe-\(UUID().uuidString)-\(index).download",
                        isDirectory: false
                    )
                try manager.copyItem(at: source, to: destinationStagingURL)
                destinationStagingURLs.append(destinationStagingURL)
            }
            for (destinationStagingURL, target) in zip(
                destinationStagingURLs,
                transfer.targetURLs
            ) {
                if manager.fileExists(atPath: target.path) {
                    guard transfer.allowsReplacingTarget,
                          transfer.targetURLs.count == 1 else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    _ = try manager.replaceItemAt(target, withItemAt: destinationStagingURL)
                } else {
                    try manager.moveItem(at: destinationStagingURL, to: target)
                }
                installedTargets.append(target)
            }
            try? manager.removeItem(at: transfer.stagingDirectory)
            return true
        } catch {
            for target in installedTargets where manager.fileExists(atPath: target.path) {
                try? manager.removeItem(at: target)
            }
            for url in destinationStagingURLs where manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
            try? manager.removeItem(at: transfer.stagingDirectory)
            return false
        }
    }

    private static func prepareRemoteFilePlaceholders(
        files: [ClipboardRemoteFileDescriptor]
    ) -> (directory: URL, urls: [URL])? {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("FarframeRDP-Clipboard", isDirectory: true)
        do {
            try manager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var rootStatus = stat()
            guard lstat(root.path, &rootStatus) == 0,
                  rootStatus.st_mode & S_IFMT == S_IFDIR,
                  rootStatus.st_mode & S_IFMT != S_IFLNK,
                  chmod(root.path, 0o700) == 0 else {
                return nil
            }
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var urls: [URL] = []
            do {
                for file in files {
                    let url = directory.appendingPathComponent(file.name, isDirectory: false)
                    let descriptor = open(
                        url.path,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                        0o600
                    )
                    guard descriptor >= 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let truncated = ftruncate(descriptor, off_t(file.size))
                    let closed = close(descriptor)
                    guard truncated == 0, closed == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    if let date = file.modificationDate {
                        try manager.setAttributes(
                            [.modificationDate: date],
                            ofItemAtPath: url.path
                        )
                    }
                    urls.append(url)
                }
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
            return (directory, urls)
        } catch {
            return nil
        }
    }

    private func removeOwnedRemoteFiles() {
        guard let directory = ownedRemoteFileDirectory else { return }
        ownedRemoteFileDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Data {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 {
            self[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
    }

    mutating func writeInt32(_ value: Int32, at offset: Int) {
        writeUInt32(UInt32(bitPattern: value), at: offset)
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    func int32(at offset: Int) -> Int32? {
        uint32(at: offset).map(Int32.init(bitPattern:))
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
