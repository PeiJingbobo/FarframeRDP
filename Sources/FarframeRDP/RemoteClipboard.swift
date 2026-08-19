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

    private static let pngType = NSPasteboard.PasteboardType("public.png")
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var applyingRemoteContent = false
    private var ownedRemoteFileDirectory: URL?
    private var contentRevision: UInt64 = 0
    private var latestContent = ClipboardPayloadSet()
    var onLocalContentChange: (@MainActor (ClipboardPayloadSet) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        publishCurrentContent()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        contentRevision &+= 1
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
        removeOwnedRemoteFiles()
        publishCurrentContent()
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
