import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An open file read in fixed-size pieces through one reusable buffer.
final class FileInput {
    private let descriptor: Int32
    private let path: String
    private var buffer: [UInt8] = []

    init(_ url: URL) throws(XMLTVError) {
        guard url.isFileURL else { throw XMLTVError(.notAFileURL(url.absoluteString)) }
        path = url.path
        descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { let code = errno; throw XMLTVError(.io(operation: "open", path: path, errno: code)) }
    }

    deinit { close(descriptor) }

    /// Reads up to `count` bytes and passes them to `body`. Returns false at the end of the file.
    func read(_ count: Int, _ body: (UnsafeBufferPointer<UInt8>) throws(XMLTVError) -> Void) throws(XMLTVError) -> Bool {
        if buffer.count < count { buffer = [UInt8](repeating: 0, count: count) }
        let descriptor = self.descriptor
        // `errno` is read inside the closure, straight after `read(2)` fails.
        let (n, code): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
            while true {
                let n = systemRead(descriptor, raw.baseAddress, count)
                guard n < 0 else { return (n, 0) }
                let code = errno
                if code != EINTR { return (n, code) }
            }
        }
        if n < 0 { throw XMLTVError(.io(operation: "read", path: path, errno: code)) }
        if n == 0 { return false }
        try buffer.withUnsafeBufferPointer { buffer throws(XMLTVError) in
            try body(UnsafeBufferPointer(rebasing: buffer[..<n]))
        }
        return true
    }
}

/// `read(2)`, named so it is not confused with ``FileInput/read(_:_:)``.
@inline(__always)
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}
