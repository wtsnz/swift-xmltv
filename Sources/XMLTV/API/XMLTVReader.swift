import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A record from the top level of an XMLTV document.
public enum XMLTVItem: Sendable, Hashable {
    case channel(Channel)
    case programme(Programme)
}

/// Reads an XMLTV document one record at a time, in document order, using memory proportional
/// to the largest record rather than to the file.
///
/// ```swift
/// var reader = try XMLTVReader(contentsOf: url)
/// while let item = try reader.next() {
///     switch item {
///     case .channel(let channel): store.upsert(channel)
///     case .programme(let programme): store.insert(programme)
///     }
/// }
/// ```
///
/// The reader is serial. To parse a file into memory as fast as possible, use ``XMLTVDocument``,
/// which uses every core.
public struct XMLTVReader: ~Copyable {
    /// The decoder state lives in a class so that the public type's layout does not depend on
    /// internal types.
    private let state: State

    /// Opens a file for reading. Gzip compression is detected from the content.
    public init(contentsOf url: URL, options: ParseOptions = ParseOptions()) throws(XMLTVError) {
        state = State(source: .file(try FileInput(url)), options: options)
    }

    /// Reads a document held in memory, compressed or not.
    public init(data: Data, options: ParseOptions = ParseOptions()) {
        state = State(source: .data(data, offset: 0), options: options)
    }

    /// The attributes of the root `<tv>` element, once it has been read.
    public var info: TVInfo? { state.stream.info }

    /// Diagnostics and status so far. Complete once ``next()`` has returned nil.
    public var report: ParseReport { state.stream.report }

    /// The next channel or programme, or nil at the end of the document.
    public mutating func next() throws(XMLTVError) -> XMLTVItem? {
        try state.next()
    }

    private final class State {
        enum Source {
            case file(FileInput)
            case data(Data, offset: Int)
        }

        static let readSize = 1 << 20

        var stream: StreamDecoder
        var source: Source
        var isExhausted = false

        init(source: Source, options: ParseOptions) {
            self.stream = StreamDecoder(options: options)
            self.source = source
        }

        func next() throws(XMLTVError) -> XMLTVItem? {
            while true {
                switch try stream.next() {
                case .item(let item):
                    return item
                case .end:
                    return nil
                case .needsInput:
                    try readMore()
                }
            }
        }

        private func readMore() throws(XMLTVError) {
            guard !isExhausted else { return }
            switch source {
            case .file(let file):
                let appended = try file.read(Self.readSize) { bytes throws(XMLTVError) in try stream.append(bytes) }
                if !appended {
                    isExhausted = true
                    try stream.finish()
                }
            case .data(let data, let offset):
                let end = min(data.count, offset + Self.readSize)
                if offset == end {
                    isExhausted = true
                    try stream.finish()
                    return
                }
                let result: Result<Void, XMLTVError> = data.withUnsafeBytes { raw in
                    let slice = UnsafeBufferPointer(rebasing: raw.bindMemory(to: UInt8.self)[offset..<end])
                    do throws(XMLTVError) {
                        try stream.append(slice)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                try result.get()
                source = .data(data, offset: end)
            }
        }
    }
}

/// An open file read in fixed-size pieces through one reusable buffer.
final class FileInput {
    private let descriptor: Int32
    private let path: String
    private var buffer: [UInt8] = []

    init(_ url: URL) throws(XMLTVError) {
        path = url.path
        descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw XMLTVError(.io(operation: "open \(path)", errno: errno)) }
    }

    deinit { close(descriptor) }

    /// Reads up to `count` bytes and passes them to `body`. Returns false at the end of the file.
    func read(_ count: Int, _ body: (UnsafeBufferPointer<UInt8>) throws(XMLTVError) -> Void) throws(XMLTVError) -> Bool {
        if buffer.count < count { buffer = [UInt8](repeating: 0, count: count) }
        let descriptor = self.descriptor
        let n: Int = buffer.withUnsafeMutableBytes { raw in
            while true {
                let n = systemRead(descriptor, raw.baseAddress, count)
                if n < 0 && errno == EINTR { continue }
                return n
            }
        }
        if n < 0 { throw XMLTVError(.io(operation: "read \(path)", errno: errno)) }
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
