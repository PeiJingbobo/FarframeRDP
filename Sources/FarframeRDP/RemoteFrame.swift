import Foundation

struct RemoteDesktopSize: Equatable, Sendable {
    static let maximumDimension = 16_384
    static let maximumBufferBytes = 256 * 1_024 * 1_024

    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        let (rowBytes, rowBytesOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0,
              width <= Self.maximumDimension,
              height <= Self.maximumDimension,
              !rowBytesOverflow,
              rowBytes > 0,
              height <= Self.maximumBufferBytes / rowBytes else {
            return nil
        }
        self.width = width
        self.height = height
    }

    var packedBytesPerRow: Int {
        width * 4
    }

    var packedByteCount: Int {
        packedBytesPerRow * height
    }
}

struct RemoteFrameRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init?(x: Int, y: Int, width: Int, height: Int, desktop: RemoteDesktopSize) {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= desktop.width - width,
              y <= desktop.height - height else {
            return nil
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func union(_ other: RemoteFrameRect, desktop: RemoteDesktopSize) -> RemoteFrameRect {
        let left = min(x, other.x)
        let top = min(y, other.y)
        let right = max(x + width, other.x + other.width)
        let bottom = max(y + height, other.y + other.height)
        return RemoteFrameRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
            desktop: desktop
        )!
    }
}

struct RemoteFrameUpdate: Equatable, Sendable {
    let desktopSize: RemoteDesktopSize
    let dirtyRect: RemoteFrameRect
    let pixels: Data
    let sequenceNumber: UInt64

    init?(
        desktopSize: RemoteDesktopSize,
        dirtyRect: RemoteFrameRect,
        pixels: Data,
        sequenceNumber: UInt64
    ) {
        guard dirtyRect.width <= Int.max / 4 else {
            return nil
        }
        let bytesPerRow = dirtyRect.width * 4
        guard dirtyRect.height <= Int.max / bytesPerRow,
              pixels.count == bytesPerRow * dirtyRect.height else {
            return nil
        }
        self.desktopSize = desktopSize
        self.dirtyRect = dirtyRect
        self.pixels = pixels
        self.sequenceNumber = sequenceNumber
    }

    var bytesPerRow: Int {
        dirtyRect.width * 4
    }
}

final class RemoteFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var desktopSize: RemoteDesktopSize?
    private var framebuffer = Data()
    private var pendingDirtyRect: RemoteFrameRect?
    private var latestSequenceNumber: UInt64 = 0
    private var notificationPending = false

    func ingest(
        desktopWidth: Int,
        desktopHeight: Int,
        sourceStride: Int,
        pixels: UnsafePointer<UInt8>,
        bufferLength: Int,
        dirtyX: Int,
        dirtyY: Int,
        dirtyWidth: Int,
        dirtyHeight: Int,
        sequenceNumber: UInt64
    ) -> Bool {
        guard let size = RemoteDesktopSize(width: desktopWidth, height: desktopHeight),
              sourceStride >= size.packedBytesPerRow,
              sourceStride <= bufferLength,
              size.height <= bufferLength / sourceStride,
              let rect = RemoteFrameRect(
                x: dirtyX,
                y: dirtyY,
                width: dirtyWidth,
                height: dirtyHeight,
                desktop: size
              ) else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        if desktopSize != size {
            desktopSize = size
            framebuffer = Data(repeating: 0, count: size.packedByteCount)
            pendingDirtyRect = RemoteFrameRect(
                x: 0,
                y: 0,
                width: size.width,
                height: size.height,
                desktop: size
            )
        }

        let destinationStride = size.packedBytesPerRow
        let copyByteCount = rect.width * 4
        framebuffer.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                return
            }
            for row in 0..<rect.height {
                let sourceOffset = (rect.y + row) * sourceStride + rect.x * 4
                let destinationOffset = (rect.y + row) * destinationStride + rect.x * 4
                memcpy(
                    destinationBase.advanced(by: destinationOffset),
                    pixels.advanced(by: sourceOffset),
                    copyByteCount
                )
            }
        }

        if let pendingDirtyRect {
            self.pendingDirtyRect = pendingDirtyRect.union(rect, desktop: size)
        } else {
            pendingDirtyRect = rect
        }
        latestSequenceNumber = max(latestSequenceNumber, sequenceNumber)

        if notificationPending {
            return false
        }
        notificationPending = true
        return true
    }

    @discardableResult
    func consumePendingFrame(
        _ consumer: (
            RemoteDesktopSize,
            RemoteFrameRect,
            UnsafeRawBufferPointer,
            Int,
            UInt64
        ) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let size = desktopSize, let rect = pendingDirtyRect else {
            notificationPending = false
            return false
        }

        framebuffer.withUnsafeBytes { source in
            consumer(
                size,
                rect,
                source,
                size.packedBytesPerRow,
                latestSequenceNumber
            )
        }

        pendingDirtyRect = nil
        notificationPending = false
        return true
    }
}


struct RemoteCursorShape: Equatable, Sendable {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let pixels: Data

    init?(
        width: Int,
        height: Int,
        hotspotX: Int,
        hotspotY: Int,
        pixels: Data
    ) {
        guard width > 0, height > 0, width <= 512, height <= 512,
              hotspotX >= 0, hotspotY >= 0,
              hotspotX < width, hotspotY < height,
              width <= Int.max / 4,
              height <= Int.max / (width * 4),
              pixels.count == width * height * 4 else {
            return nil
        }
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }

    var bytesPerRow: Int {
        width * 4
    }
}

enum RemoteCursorUpdate: Equatable, Sendable {
    case shape(RemoteCursorShape)
    case position(x: Int, y: Int)
    case hidden
    case defaultCursor
}


enum RemoteScalingMode: Int, Equatable, Sendable {
    case fit = 0
    case actualPixels = 1
}
