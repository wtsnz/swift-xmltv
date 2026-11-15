import Foundation

/// A record from the top level of an XMLTV document.
///
/// These two cases are the whole of it, and that will not change, so a `switch` over an item
/// needs no `default`. Other top-level elements are skipped. If the library ever offers them,
/// it will be through a separate API, not a third case here.
public enum XMLTVItem: Sendable, Hashable {
    case channel(Channel)
    case programme(Programme)
}

/// Reads an XMLTV document one record at a time, in document order, in bounded memory: a 1 MiB
/// read buffer, up to 1 MiB of decompressed gzip, a table of the first 4 MiB of distinct
/// strings, and the record being read, which ``XMLTVOptions/maximumRecordSize`` limits.
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
///
/// A reader is a single pass over its input, and it is noncopyable so that sharing one is a
/// compile error rather than two owners silently taking records from the same cursor. Store it
/// in a class, an actor or another noncopyable type, and pass it as `inout`, or `consuming` to
/// hand it over. It is `Sendable`, so it can be moved into a task or an actor;
/// <doc:ChoosingAnEntryPoint#Concurrency> shows how.
public struct XMLTVReader: ~Copyable, @unchecked Sendable {
    /// The decoder state lives in a class so that the public type's layout does not depend on
    /// internal types. The reader is `@unchecked Sendable` because it is noncopyable: whoever
    /// holds it owns the state alone, and `next()` needs exclusive access.
    private let state: State

    /// Opens a file for reading. Gzip compression is detected from the content. The URL must be a
    /// file URL.
    public init(contentsOf url: URL, options: XMLTVOptions = XMLTVOptions()) throws(XMLTVError) {
        state = State(source: .file(try FileInput(url)), options: options)
    }

    /// Reads a document held in memory, compressed or not.
    public init(data: Data, options: XMLTVOptions = XMLTVOptions()) {
        state = State(source: .data(data, offset: 0), options: options)
    }

    /// The attributes of the root `<tv>` element. Nil until the first call to ``next()``, which
    /// reads them.
    public var info: TVInfo? { state.stream.info }

    /// Diagnostics and status so far. Complete once ``next()`` has returned nil.
    public var report: XMLTVReport { state.stream.report }

    /// The next channel or programme, or nil at the end of the document.
    ///
    /// After it throws, the reader is finished: every later call throws the same error.
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

        init(source: Source, options: XMLTVOptions) {
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
