import Dispatch
import Foundation
import Synchronization

/// Parses a whole in-memory document, in parallel when it is large enough.
///
/// **Speculative split, verified handoff.** The buffer is cut into chunks at positions that look
/// like `<programme`, and every chunk is decoded at once on its own core. A guess can be wrong:
/// the text may sit inside a comment, a CDATA section or an extension element. So chunks are
/// trusted only after a sequential check:
///
/// 1. Chunk 0 starts at the true beginning of the document, so it is correct. It stops at the
///    first top-level element at or after the next split. That stop is a true top-level position.
/// 2. Chunk *i* is accepted from the first of its top-level element starts that equals the true
///    position where chunk *i−1* stopped. At a true top-level position the decoder's state is
///    empty: no open elements, no namespaces, no entities. So from there on its output is exactly
///    what a sequential parse produces.
/// 3. If chunk *i* never lines up with the true position, the range is decoded again from that
///    position. Decoding resyncs onto chunk *i* as soon as a position matches one of its element
///    starts, so a bad guess costs only the stretch before that point.
///
/// The output (records, diagnostics, errors and truncation) is identical to a serial parse for
/// any choice of split points. The test suite checks this with adversarial input.
enum DocumentDriver {
    struct Output {
        var info: TVInfo
        var channels: [Channel]
        var programmes: [Programme]
        var report: ParseReport
    }

    static let parallelThreshold = 1 << 20
    static let minimumChunkSize = 256 << 10

    /// - Parameter splits: Chunk start offsets, beginning with 0 and ending with `bytes.count`.
    ///   Normally chosen by ``splitPoints(_:parallelism:)``. Tests pass adversarial ones; any
    ///   ascending list gives the same output.
    static func parse(
        _ bytes: UnsafeBufferPointer<UInt8>, input: DocumentInput.InputInfo, options: ParseOptions, splits: [Int]? = nil
    ) throws(XMLTVError) -> Output {
        let splits = splits ?? splitPoints(bytes, parallelism: options.parallelism)
        let chunkCount = splits.count - 1

        let results = UnsafeMutableBufferPointer<ChunkResult?>.allocate(capacity: chunkCount)
        results.initialize(repeating: nil)
        defer { results.deinitialize().deallocate() }
        let sharedResults = UncheckedSendable(results)
        let sharedBytes = UncheckedSendable(bytes)
        forEachChunk(count: chunkCount, threads: threadCount(options.parallelism)) { index in
            sharedResults.value[index] = decodeChunk(
                sharedBytes.value, from: splits[index], boundary: splits[index + 1],
                phase: index == 0 ? .prolog : .body, options: options, syncMarks: nil)
        }

        let segments = stitch(bytes, results: results.map { $0! }, splits: splits, options: options)
        return try assemble(bytes, segments: segments, input: input, options: options)
    }

    /// Runs `body` for every chunk index on at most `threads` threads. Chunks are handed out in
    /// order from a shared counter, so faster cores take more of them.
    private static func forEachChunk(count: Int, threads: Int, _ body: @Sendable (Int) -> Void) {
        let workers = min(count, threads)
        guard workers > 1 else {
            for index in 0..<count { body(index) }
            return
        }
        let nextChunk = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                let index = nextChunk.add(1, ordering: .relaxed).oldValue
                guard index < count else { return }
                body(index)
            }
        }
    }

    private static func threadCount(_ parallelism: ParseOptions.Parallelism) -> Int {
        switch parallelism {
        case .serial: 1
        case .threads(let n): max(1, n)
        case .automatic: ProcessInfo.processInfo.activeProcessorCount
        }
    }

    // MARK: Planning

    /// Offsets where chunks start: 0, then the first plausible `<programme` at or after each
    /// equal division, then the end of the buffer.
    static func splitPoints(_ bytes: UnsafeBufferPointer<UInt8>, parallelism: ParseOptions.Parallelism) -> [Int] {
        let count = bytes.count
        let threads = parallelism == .automatic && count < parallelThreshold ? 1 : threadCount(parallelism)
        // Several chunks per thread balance the load between performance and efficiency cores.
        let chunkCount = threads == 1 ? 1 : min(threads * 4, max(1, count / minimumChunkSize))
        guard chunkCount > 1, let base = bytes.baseAddress else { return [0, count] }

        var splits = [0]
        for k in 1..<chunkCount {
            var candidate = max(count / chunkCount * k, splits.last! + 1)
            while true {
                candidate = ByteSearch.first("<programme", in: base, from: candidate, end: count)
                guard candidate + 10 < count else { candidate = count; break }
                let next = base[candidate + 10]
                if next.isXMLWhitespace || next == UInt8(ascii: ">") || next == UInt8(ascii: "/") { break }
                candidate += 1
            }
            if candidate >= count { break }
            if candidate > splits.last! { splits.append(candidate) }
        }
        splits.append(count)
        return splits
    }

    // MARK: Decoding

    /// Everything one chunk decoded, with the offsets needed to splice it.
    final class ChunkResult {
        enum Termination {
            /// Stopped before a top-level element at or after the chunk boundary, at this offset.
            case boundary(Int)
            /// Stopped at an element start that the speculative chunk being repaired also
            /// decoded, so the rest can be taken from that chunk.
            case synced(Int)
            case end
            case failed(XMLTVError)
        }

        let start: Int
        var termination = Termination.end
        var info: TVInfo?
        var programmes = RecordBuffer<Programme>()
        var programmeStarts: [Int] = []
        var channels: [Channel] = []
        var channelStarts: [Int] = []
        /// Start offset of every top-level element decoded, ascending.
        var marks: [Int] = []
        var diagnostics: Diagnostics

        init(start: Int, options: ParseOptions) {
            self.start = start
            self.diagnostics = Diagnostics(policy: options.policy, sampleLimit: options.diagnosticLimit, recordsOffsets: true)
        }
    }

    /// Decodes top-level elements from `start` until one starts at or after `boundary`. With
    /// `syncMarks`, it also stops at the first element start found in that sorted list.
    static func decodeChunk(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, boundary: Int,
        phase: XMLTVDecoder.Phase, options: ParseOptions, syncMarks: [Int]?
    ) -> ChunkResult {
        let result = ChunkResult(start: start, options: options)
        var decoder = XMLTVDecoder(
            scanner: XMLScanner(bytes, position: start), phase: phase, options: options, recordsDiagnosticOffsets: true)
        let isLastChunk = boundary >= bytes.count
        let boundary = isLastChunk ? Int.max : boundary
        var markIndex = 0

        do {
            decoding: while true {
                var limit = boundary
                if let syncMarks {
                    while markIndex < syncMarks.count && syncMarks[markIndex] < decoder.scanner.position { markIndex += 1 }
                    if markIndex < syncMarks.count { limit = min(limit, syncMarks[markIndex]) }
                }
                switch try decoder.next(boundary: limit) {
                case .programme(let programme):
                    result.marks.append(decoder.elementStart)
                    result.programmeStarts.append(decoder.elementStart)
                    result.programmes.append(programme)
                case .channel(let channel):
                    result.marks.append(decoder.elementStart)
                    result.channelStarts.append(decoder.elementStart)
                    result.channels.append(channel)
                case .skipped:
                    result.marks.append(decoder.elementStart)
                case .rootClosed:
                    continue
                case .boundary:
                    let position = decoder.scanner.position
                    if position >= boundary {
                        result.termination = .boundary(position)
                        break decoding
                    }
                    if let syncMarks, markIndex < syncMarks.count, syncMarks[markIndex] == position {
                        result.termination = .synced(position)
                        break decoding
                    }
                case .end:
                    result.termination = .end
                    break decoding
                }
            }
        } catch {
            result.termination = .failed(error)
        }
        result.info = decoder.info
        result.diagnostics = decoder.diagnostics
        return result
    }

    // MARK: Verification

    /// A run of a chunk's output that matches the sequential parse: everything at or after `from`.
    struct Segment {
        var result: ChunkResult
        var from: Int
    }

    /// Chooses the segments that make up the sequential parse, re-decoding wherever a speculative
    /// chunk does not line up.
    static func stitch(
        _ bytes: UnsafeBufferPointer<UInt8>, results: [ChunkResult], splits: [Int], options: ParseOptions
    ) -> [Segment] {
        var segments = [Segment(result: results[0], from: 0)]
        var current = results[0]
        for index in 1..<results.count {
            guard case .boundary(let truePosition) = current.termination else { break }
            let candidate = results[index]
            if candidate.start == truePosition
                || contains(candidate.marks, truePosition) && !lostSamples(candidate, keepingFrom: truePosition) {
                segments.append(Segment(result: candidate, from: truePosition))
                current = candidate
                continue
            }
            if contains(candidate.marks, truePosition) {
                // The chunk lines up, but it filled its diagnostic samples with material before
                // the true position. Decode the range again so the samples are the right ones.
                let redo = decodeChunk(
                    bytes, from: truePosition, boundary: splits[index + 1], phase: .body, options: options, syncMarks: nil)
                segments.append(Segment(result: redo, from: truePosition))
                current = redo
                continue
            }
            let repair = decodeChunk(
                bytes, from: truePosition, boundary: splits[index + 1],
                phase: .body, options: options, syncMarks: candidate.marks)
            segments.append(Segment(result: repair, from: truePosition))
            if case .synced(let position) = repair.termination {
                segments.append(Segment(result: candidate, from: position))
                current = candidate
            } else {
                current = repair
            }
        }
        return segments
    }

    /// Whether a chunk's diagnostic samples, filtered to `from`, miss diagnostics it reported
    /// after `from`, because samples before `from` used up its budget.
    private static func lostSamples(_ result: ChunkResult, keepingFrom from: Int) -> Bool {
        let samples = result.diagnostics.samples
        guard samples.count == result.diagnostics.sampleLimit, let first = samples.first, first.byteOffset < from else {
            return false
        }
        let kept = samples.count - lowerBound(samples.map(\.byteOffset), from)
        let reported = result.diagnostics.count - lowerBound(result.diagnostics.offsets, from)
        return kept < min(reported, result.diagnostics.sampleLimit)
    }

    // MARK: Assembly

    static func assemble(
        _ bytes: UnsafeBufferPointer<UInt8>, segments: [Segment], input: DocumentInput.InputInfo, options: ParseOptions
    ) throws(XMLTVError) -> Output {
        var report = ParseReport()
        report.encoding = input.encoding
        report.byteCount = bytes.count

        // How the sequential parse ended.
        if case .failed(var error) = segments.last!.result.termination {
            let isTruncation = error.kind == .unexpectedEndOfInput
            guard isTruncation, options.policy == .lenient, segments[0].result.info != nil else {
                if isTruncation && segments[0].result.info == nil { error.kind = .notXMLTV }
                throw located(error, in: bytes)
            }
            report.isTruncated = true
        }

        // Channels and diagnostics are few, so they are copied. Programmes are moved.
        var channels: [Channel] = []
        var diagnostics: [XMLTVDiagnostic] = []
        var programmeCount = 0
        var firstProgramme: [Int] = []
        for segment in segments {
            let result = segment.result
            let firstChannel = lowerBound(result.channelStarts, segment.from)
            channels.append(contentsOf: result.channels[firstChannel...])
            let first = lowerBound(result.programmeStarts, segment.from)
            firstProgramme.append(first)
            programmeCount += result.programmeStarts.count - first

            let firstDiagnostic = lowerBound(result.diagnostics.offsets, segment.from)
            report.diagnosticCount += result.diagnostics.count - firstDiagnostic
            for sample in result.diagnostics.samples where sample.byteOffset >= segment.from {
                if diagnostics.count < options.diagnosticLimit { diagnostics.append(sample) }
            }
        }
        // Problems found at the end, or before parsing (in decompression or transcoding), are
        // reported at the end of the document, which keeps the list in document order.
        let endProblems = (report.isTruncated ? [XMLTVError.Kind.unexpectedEndOfInput] : []) + input.problems
        for kind in endProblems {
            report.diagnosticCount += 1
            if diagnostics.count < options.diagnosticLimit {
                diagnostics.append(XMLTVDiagnostic(kind: kind, byteOffset: bytes.count, line: 0))
            }
        }
        report.diagnostics = withLineNumbers(diagnostics, in: bytes)

        let programmes = [Programme](unsafeUninitializedCapacity: programmeCount) { buffer, initialized in
            var written = 0
            for (segment, first) in zip(segments, firstProgramme) {
                written += segment.result.programmes.moveElements(from: first, to: buffer.baseAddress! + written)
            }
            initialized = written
        }

        return Output(info: segments[0].result.info ?? TVInfo(), channels: channels, programmes: programmes, report: report)
    }

    // MARK: Helpers

    private static func lowerBound(_ sorted: [Int], _ value: Int) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func contains(_ sorted: [Int], _ value: Int) -> Bool {
        let index = lowerBound(sorted, value)
        return index < sorted.count && sorted[index] == value
    }

    /// Fills in the line and column of an error. Errors about the input as a whole (I/O,
    /// compression, encoding) have no position.
    static func located(_ error: XMLTVError, in bytes: UnsafeBufferPointer<UInt8>) -> XMLTVError {
        switch error.kind {
        case .io, .invalidCompressedData, .unsupportedEncoding, .invalidEncoding: return error
        default: break
        }
        guard let base = bytes.baseAddress else { return error }
        var error = error
        let offset = min(error.byteOffset, bytes.count)
        error.line = ByteSearch.countNewlines(in: base, from: 0, end: offset) + 1
        var lineStart = offset
        while lineStart > 0 && base[lineStart - 1] != 0x0A { lineStart -= 1 }
        error.column = offset - lineStart + 1
        return error
    }

    /// Fills in the line numbers of diagnostics, which are in document order, in one pass.
    static func withLineNumbers(_ diagnostics: [XMLTVDiagnostic], in bytes: UnsafeBufferPointer<UInt8>) -> [XMLTVDiagnostic] {
        guard let base = bytes.baseAddress else { return diagnostics }
        var line = 1, position = 0
        return diagnostics.map { diagnostic in
            var diagnostic = diagnostic
            let offset = min(diagnostic.byteOffset, bytes.count)
            if offset >= position {
                line += ByteSearch.countNewlines(in: base, from: position, end: offset)
                position = offset
            }
            diagnostic.line = line
            return diagnostic
        }
    }
}

/// Lets the parallel loop share buffers that each iteration only touches at its own index.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
