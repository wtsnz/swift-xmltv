import Foundation

/// The records of an XMLTV document arriving as a sequence of byte chunks, for example from a
/// network download.
///
/// ```swift
/// for try await item in XMLTVItems(chunks: downloadChunks) {
///     if case .programme(let programme) = item { try await database.insert(programme) }
/// }
/// ```
///
/// Iteration is pull-driven. Each call to `next()` decodes up to the next record, reading
/// more chunks only as needed. There is no background task, so a slow consumer applies
/// backpressure to the source. Errors from the source are rethrown unchanged. Parse errors are
/// ``XMLTVError``.
///
/// To see the diagnostics, or whether a download was cut off, iterate explicitly and read
/// the iterator's ``AsyncIterator/report`` at the end:
///
/// ```swift
/// var items = XMLTVItems(chunks: downloadChunks).makeAsyncIterator()
/// while let item = try await items.next() { … }
/// if items.report.isTruncated { … }
/// ```
public struct XMLTVItems<Chunks: AsyncSequence>: AsyncSequence where Chunks.Element: ContiguousBytes {
    public typealias Element = XMLTVItem

    private let chunks: Chunks
    private let options: ParseOptions

    public init(chunks: Chunks, options: ParseOptions = ParseOptions()) {
        self.chunks = chunks
        self.options = options
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(upstream: chunks.makeAsyncIterator(), state: State(options: options))
    }

    /// Decodes records on demand, reading chunks only as needed.
    public struct AsyncIterator: AsyncIteratorProtocol {
        var upstream: Chunks.AsyncIterator
        let state: State

        /// Diagnostics and status so far. Complete once `next()` has returned nil.
        public var report: ParseReport { state.decoder.report }

        /// The attributes of the root `<tv>` element, once it has been read.
        public var info: TVInfo? { state.decoder.info }

        /// The next channel or programme, or nil at the end of the document.
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> XMLTVItem? {
            while true {
                switch try state.decoder.next() {
                case .item(let item):
                    return item
                case .end:
                    return nil
                case .needsInput:
                    if state.isFinished { return nil }
                    if let chunk = try await upstream.next(isolation: actor) {
                        try chunk.withUnsafeBytes { raw throws(XMLTVError) in
                            try state.decoder.append(raw.bindMemory(to: UInt8.self))
                        }
                    } else {
                        state.isFinished = true
                        try state.decoder.finish()
                    }
                }
            }
        }

        public mutating func next() async throws -> XMLTVItem? {
            try await next(isolation: nil)
        }
    }

    /// Holds the noncopyable decoder for the copyable iterator. Copies of an iterator share it.
    final class State {
        var decoder: StreamDecoder
        var isFinished = false

        init(options: ParseOptions) {
            decoder = StreamDecoder(options: options)
        }
    }
}
