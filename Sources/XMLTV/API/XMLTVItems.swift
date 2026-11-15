import Foundation
import Synchronization

/// The records of an XMLTV document arriving as a sequence of byte chunks, for example from a
/// network download.
///
/// ```swift
/// let items = XMLTVItems(chunks: downloadChunks)
/// for try await item in items {
///     if case .programme(let programme) = item { try await database.insert(programme) }
/// }
/// if let report = items.report, report.isTruncated { … }   // the download was cut off
/// ```
///
/// A cut-off download ends the loop normally, after its last complete record, so check
/// ``report`` once the loop has finished. It also has the diagnostics.
///
/// Iteration is pull-driven. Each call to `next()` decodes up to the next record, reading
/// more chunks only as needed. There is no background task, so memory stays bounded as long
/// as the chunk source itself waits to be asked: `URLSession.AsyncBytes` does, but an
/// `AsyncStream` fed by a delegate buffers whatever it is given. Errors from the source are
/// rethrown unchanged. Parse errors are ``XMLTVError``. If the task is cancelled and the source
/// ends early because of it, as `AsyncStream` does, iteration throws `CancellationError`.
///
/// For a download of known size, saving it to a file and using ``XMLTVDocument`` is usually
/// simpler and faster; see <doc:ChoosingAnEntryPoint>.
public struct XMLTVItems<Chunks: AsyncSequence>: AsyncSequence where Chunks.Element: ContiguousBytes {
    public typealias Element = XMLTVItem

    private let chunks: Chunks
    private let options: XMLTVOptions
    private let outcome = Outcome()

    public init(chunks: Chunks, options: XMLTVOptions = XMLTVOptions()) {
        self.chunks = chunks
        self.options = options
    }

    /// The report of the most recent iteration to end, or nil before one has. Copies of the
    /// sequence share it.
    ///
    /// A `for try await` loop hides its iterator, so this is where the loop's report is found
    /// once the loop has finished. An iteration ends when it reaches the end of the document,
    /// and also when the loop exits early, by `break` or a thrown error, and its iterator is
    /// released. The report then covers the records read so far, and ``XMLTVReport/isTruncated``
    /// is false, because the end was never reached: check for a thrown error first. An iterator
    /// that is made but never advanced does not count, but any later iteration does, including
    /// one that `first(where:)` or `contains(_:)` starts. While the loop runs, the iterator's
    /// ``AsyncIterator/report`` has the report so far.
    public var report: XMLTVReport? { outcome.value.withLock { $0?.report } }

    /// The attributes of the root `<tv>` element, from the same iteration as ``report``.
    public var info: TVInfo? { outcome.value.withLock { $0?.info } }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: State(upstream: chunks.makeAsyncIterator(), options: options, outcome: outcome))
    }

    /// Decodes records on demand, reading chunks only as needed.
    ///
    /// An iterator is a single cursor: copies of it share their position, so advancing one
    /// advances all of them. Advance it from one task at a time: two tasks interleaving calls,
    /// even on one actor, stop the program with a precondition failure. To iterate from an
    /// actor, keep the iterator in a local variable of an actor method. Both `next()` methods
    /// decode on the caller's actor, and read the chunk source there.
    public struct AsyncIterator: AsyncIteratorProtocol {
        let state: State

        /// Diagnostics and status so far. Complete once `next()` has returned nil.
        public var report: XMLTVReport { state.decoder.report }

        /// The attributes of the root `<tv>` element, once it has been read.
        public var info: TVInfo? { state.decoder.info }

        /// The next channel or programme, or nil at the end of the document.
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> XMLTVItem? {
            // Copies share one cursor. Two tasks on one actor can still interleave calls across
            // the `await` below, which would hand the decoder chunks out of order; make that a
            // clear failure rather than corrupt output.
            precondition(!state.isAdvancing, "An XMLTVItems iterator was advanced by two tasks at once")
            state.isAdvancing = true
            defer { state.isAdvancing = false }
            state.hasStarted = true
            while true {
                switch try state.decoder.next() {
                case .item(let item):
                    return item
                case .end:
                    state.publish()
                    return nil
                case .needsInput:
                    if state.isFinished {
                        state.publish()
                        return nil
                    }
                    if let chunk = try await state.upstream.next(isolation: actor) {
                        // Untyped: `withUnsafeBytes` rethrows untyped errors, and the Swift 6.2.3
                        // compiler crashes converting a typed-throws closure for it.
                        try chunk.withUnsafeBytes { raw in
                            try state.decoder.append(raw.bindMemory(to: UInt8.self))
                        }
                    } else {
                        // `AsyncStream` and others end, rather than throw, when the task is
                        // cancelled. That end is not the document's, so it must not read as a
                        // cut-off download.
                        try Task.checkCancellation()
                        state.isFinished = true
                        try state.decoder.finish()
                    }
                }
            }
        }

        /// The next channel or programme, decoded on the caller's actor, as `for try await` does.
        public nonisolated(nonsending) mutating func next() async throws -> XMLTVItem? {
            try await next(isolation: #isolation)
        }
    }

    /// One iteration: the source's iterator and the noncopyable decoder, shared by copies of
    /// the copyable ``AsyncIterator`` so that they are one cursor.
    final class State {
        var upstream: Chunks.AsyncIterator
        var decoder: StreamDecoder
        var isFinished = false
        var hasStarted = false
        var isAdvancing = false
        private var isPublished = false
        let outcome: Outcome

        init(upstream: Chunks.AsyncIterator, options: XMLTVOptions, outcome: Outcome) {
            self.upstream = upstream
            self.decoder = StreamDecoder(options: options)
            self.outcome = outcome
        }

        /// Makes this iteration's report the sequence's report, once: when the iteration reaches
        /// the end, or when it is abandoned. Later calls do nothing, so an iteration that ended
        /// long ago cannot replace the report of a newer one.
        func publish() {
            guard !isPublished else { return }
            isPublished = true
            let result = (decoder.report, decoder.info)
            outcome.value.withLock { $0 = result }
        }

        /// An iteration abandoned by `break` or an error publishes what it read. One that never
        /// started publishes nothing.
        deinit {
            if hasStarted { publish() }
        }
    }

    /// The result of the last iteration to finish, shared by copies of the sequence.
    final class Outcome: Sendable {
        let value = Mutex<(report: XMLTVReport, info: TVInfo?)?>(nil)
    }
}

extension XMLTVItems: Sendable where Chunks: Sendable {}

extension XMLTVItems {
    /// Decodes an asynchronous sequence of single bytes, such as `URLSession.AsyncBytes`.
    ///
    /// ```swift
    /// let (bytes, response) = try await URLSession.shared.bytes(from: url)
    /// let items = XMLTVItems(bytes: bytes)
    /// ```
    ///
    /// The bytes are gathered into chunks of `chunkSize` before decoding, by a loop specialised
    /// for `Bytes` that runs off the caller's actor. Gathering still costs more than parsing: on
    /// an Apple M4 Max, `URLSession.AsyncBytes` of a local file reads at about 200 MB/s this way,
    /// against about 440 MB/s for 64 KiB chunks. For the fastest result, download to a file and
    /// use ``XMLTVDocument``.
    ///
    /// `Bytes` must be `Sendable`, because the loop runs off the caller's actor. The byte
    /// sequences in Foundation are.
    public init<Bytes>(bytes: Bytes, chunkSize: Int = 64 << 10, options: XMLTVOptions = XMLTVOptions())
    where Chunks == XMLTVByteChunks<Bytes> {
        self.init(chunks: XMLTVByteChunks(bytes, chunkSize: chunkSize), options: options)
    }
}

/// Groups an asynchronous sequence of bytes into chunks, for ``XMLTVItems/init(bytes:chunkSize:options:)``.
///
/// Gathering bytes one at a time is the expensive part of reading `URLSession.AsyncBytes`, so
/// three things keep it cheap:
/// - The byte loop is built in an inlinable initializer, so it is compiled where the sequence is
///   created, specialised for the caller's byte type. Code generic over the chunk sequence then
///   calls it once per chunk.
/// - The loop is `@concurrent`. A caller on the main actor hops off it once per chunk, not once
///   per byte. That is why `Bytes` must be `Sendable`: its iterator is used off the actor that
///   made the sequence.
/// - The loop advances a local copy of the source's iterator, so the per-byte work stays in
///   registers rather than going through the closure's captured state.
///
/// If the source throws, the bytes gathered so far are returned as a final chunk, and the error
/// is thrown by the next call, so a parse sees every byte that arrived.
public struct XMLTVByteChunks<Bytes: AsyncSequence & Sendable>: AsyncSequence, Sendable where Bytes.Element == UInt8 {
    public typealias Element = [UInt8]

    @usableFromInline let makeIterator: @Sendable () -> AsyncIterator

    @inlinable
    public init(_ bytes: Bytes, chunkSize: Int = 64 << 10) {
        let chunkSize = Swift.max(1, chunkSize)
        makeIterator = {
            var upstream = bytes.makeAsyncIterator()
            var pendingError: (any Error)?
            return AsyncIterator { @concurrent in
                if let error = pendingError {
                    pendingError = nil
                    throw error
                }
                var local = upstream
                defer { upstream = local }
                var chunk: [UInt8] = []
                // A huge chunk size reserves no more than a large chunk would use.
                chunk.reserveCapacity(Swift.min(chunkSize, 1 << 20))
                do {
                    while chunk.count < chunkSize, let byte = try await local.next() {
                        chunk.append(byte)
                    }
                } catch {
                    guard !chunk.isEmpty else { throw error }
                    pendingError = error
                }
                return chunk.isEmpty ? nil : chunk
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { makeIterator() }

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline let nextChunk: @concurrent () async throws -> [UInt8]?

        @inlinable
        init(_ nextChunk: @escaping @concurrent () async throws -> [UInt8]?) {
            self.nextChunk = nextChunk
        }

        public mutating func next() async throws -> [UInt8]? {
            try await nextChunk()
        }
    }
}
