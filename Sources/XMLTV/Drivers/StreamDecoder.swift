/// Decodes a document that arrives in pieces, using constant memory. ``XMLTVReader`` and
/// ``XMLTVItems`` both drive it.
///
/// Input passes through gzip detection, encoding detection and transcoding into a UTF-8
/// window. The scanner is not resumable. Instead, a record that runs past the end of the window
/// is abandoned and decoded again from its start once more input has arrived. The decoder
/// commits nothing until a record is complete, so a retry is exact. A retry waits until the
/// input has grown by half the pending bytes, so the total re-decoding work stays linear even for
/// huge records and tiny chunks.
struct StreamDecoder: ~Copyable {
    enum Step {
        case item(XMLTVItem)
        case needsInput
        case end
    }

    private let options: XMLTVOptions
    private var decoder: XMLTVDecoder

    // Input pipeline
    private var compression: Compression = .undetermined
    private var head = ByteBuffer()              // raw bytes held until gzip can be detected
    private var transcoder: Transcoder?
    private var sniff = ByteBuffer()             // decompressed bytes held until the encoding is known
    private var inflated = ByteBuffer()          // reused gzip output

    // UTF-8 window
    private var window = ByteBuffer(capacity: 1 << 20)
    private var consumed = 0                     // bytes of `window` already decoded
    private var retryAt = 0                      // decode again only once `window.count` reaches this
    private var discardedBytes = 0               // UTF-8 bytes dropped from the front of `window`
    private var discardedNewlines = 0
    private var discardedColumn = 0              // bytes of the current line already discarded
    private var isFinal = false
    private var isEnded = false                  // the report is complete; `next()` returns `.end`
    private var inputProblems: [XMLTVError.Kind] = []
    private var inputByteCount = 0               // raw bytes appended, before decompression
    private(set) var report = XMLTVReport()

    private enum Compression { case undetermined, none, gzip(GzipInflater), failed }

    init(options: XMLTVOptions) {
        self.options = options
        self.decoder = XMLTVDecoder(
            scanner: XMLScanner(UnsafeBufferPointer(start: nil, count: 0)), phase: .prolog, options: options,
            recordsDiagnosticOffsets: false, internerBudget: Interner.streamArenaBudget)
    }

    var info: TVInfo? { decoder.info }

    // MARK: Input

    /// Adds the next piece of the raw input: compressed or not, in any supported encoding.
    mutating func append(_ raw: UnsafeBufferPointer<UInt8>) throws(XMLTVError) {
        inputByteCount += raw.count
        compactWindow()
        switch compression {
        case .undetermined:
            head.append(raw)
            guard head.count >= 2 else { return }
            try resolveCompression()
        case .none:
            try appendDecompressed(raw)
        case .gzip(let inflater):
            try inflate(raw, with: inflater)
        case .failed:
            return
        }
    }

    /// Marks the end of the input.
    mutating func finish() throws(XMLTVError) {
        if case .undetermined = compression { try resolveCompression() }
        if case .gzip(let inflater) = compression, !inflater.isComplete {
            try recordInputProblem(.invalidCompressedData("truncated gzip stream"))
        }
        if transcoder == nil { try resolveEncoding() }
        // Flush a dangling UTF-16 byte or surrogate as U+FFFD.
        transcoder!.transcode(UnsafeBufferPointer(start: nil, count: 0), into: &window, isFinal: true)
        if transcoder!.replacedInvalidInput { try recordInputProblem(.invalidEncoding) }
        isFinal = true
        retryAt = 0
    }

    /// A problem in decompression or transcoding: fatal in strict mode, otherwise reported at
    /// the end of the document, as the document parser reports it.
    private mutating func recordInputProblem(_ kind: XMLTVError.Kind) throws(XMLTVError) {
        if options.policy == .strict { throw XMLTVError(kind) }
        inputProblems.append(kind)
    }

    private mutating func resolveCompression() throws(XMLTVError) {
        let held = head.bytes
        if GzipInflater.isGzip(held) {
            let inflater = try GzipInflater()
            compression = .gzip(inflater)
            try inflate(held, with: inflater)
        } else {
            compression = .none
            try appendDecompressed(held)
        }
        head = ByteBuffer()
    }

    /// Decompresses `raw`. On damaged data, what was decompressed is kept, and lenient mode
    /// parses up to the damage and ignores the rest of the input.
    private mutating func inflate(_ raw: UnsafeBufferPointer<UInt8>, with inflater: GzipInflater) throws(XMLTVError) {
        do throws(XMLTVError) {
            try inflater.inflate(raw, into: &inflated)
        } catch {
            try flushInflated()
            try recordInputProblem(error.kind)
            compression = .failed
            return
        }
        try flushInflated()
    }

    private mutating func flushInflated() throws(XMLTVError) {
        try appendDecompressed(inflated.bytes)
        inflated.removeFirst(inflated.count)
    }

    private mutating func appendDecompressed(_ bytes: UnsafeBufferPointer<UInt8>) throws(XMLTVError) {
        if transcoder != nil {
            transcoder!.transcode(bytes, into: &window, isFinal: false)
            return
        }
        sniff.append(bytes)
        if EncodingDetector.canDetect(sniff.bytes) { try resolveEncoding() }
    }

    private mutating func resolveEncoding() throws(XMLTVError) {
        let held = sniff.bytes
        let (encoding, bomLength) = try EncodingDetector.detect(held, override: options.encoding)
        report.encoding = encoding
        var transcoder = Transcoder(encoding)
        transcoder.transcode(UnsafeBufferPointer(rebasing: held[bomLength...]), into: &window, isFinal: false)
        self.transcoder = transcoder
        sniff = ByteBuffer()
    }

    /// Drops decoded bytes from the front of the window once they are at least half of it.
    private mutating func compactWindow() {
        guard consumed > 0, consumed >= window.count / 2 else { return }
        if let base = window.bytes.baseAddress {
            discardedNewlines += ByteSearch.countNewlines(in: base, from: 0, end: consumed)
            // Keep the column of the discard point, for errors on a line that began before it.
            let lineStart = ByteSearch.lineStart(of: consumed, in: base)
            discardedColumn = lineStart == 0 ? discardedColumn + consumed : consumed - lineStart
        }
        window.removeFirst(consumed)
        discardedBytes += consumed
        retryAt = max(0, retryAt - consumed)
        consumed = 0
    }

    // MARK: Decoding

    mutating func next() throws(XMLTVError) -> Step {
        if isEnded { return .end }
        while true {
            guard isFinal || window.count >= retryAt else { return .needsInput }
            let callStart = consumed
            let sampleCount = decoder.diagnostics.samples.count
            let item: TopLevelItem
            do {
                decoder.scanner.rebind(to: window.bytes, position: consumed, isComplete: isFinal)
                item = try decoder.next()
            } catch where error.kind == .unexpectedEndOfInput && !isFinal {
                decoder.diagnostics.discardPending()
                let pending = window.count - callStart
                // Retry once the input has grown by half the pending bytes. Small records
                // retry on the next chunk, and the re-decoding of a huge record stays linear.
                retryAt = window.count + max(1, pending / 2)
                return .needsInput
            } catch where error.kind == .unexpectedEndOfInput && options.policy == .lenient && decoder.info != nil {
                decoder.diagnostics.discardPending()
                report.isTruncated = true
                // The cause, such as damaged compressed data, comes before its effect.
                finishReport(endProblems: inputProblems + [.unexpectedEndOfInput])
                return .end
            } catch {
                var error = error
                if error.kind == .unexpectedEndOfInput && decoder.info == nil { error.kind = .notXMLTV }
                throw located(error)
            }

            consumed = decoder.scanner.position
            commitSamples(from: sampleCount)
            switch item {
            case .channel(let channel): return .item(.channel(channel))
            case .programme(let programme): return .item(.programme(programme))
            case .skipped, .rootClosed, .boundary: continue
            case .end where !isFinal:
                // The epilog so far is fine, but content after the root may still arrive.
                retryAt = window.count + 1
                return .needsInput
            case .end:
                finishReport(endProblems: inputProblems)
                return .end
            }
        }
    }

    /// Converts the window offsets of samples committed since `index` to document offsets.
    private mutating func commitSamples(from index: Int) {
        let window = self.window.bytes
        let discardedNewlines = self.discardedNewlines
        decoder.diagnostics.rebaseSamples(from: index, by: discardedBytes) { offset in
            discardedNewlines + ByteSearch.countNewlines(in: window.baseAddress!, from: 0, end: min(offset, window.count)) + 1
        }
        let totals = decoder.diagnostics.totals
        report.diagnostics = decoder.diagnostics.samples
        report.diagnosticCount = totals.diagnosticCount
        report.diagnosticCountsByCode = totals.diagnosticCountsByCode
        report.droppedProgrammeCount = totals.droppedProgrammeCount
        report.droppedChannelCount = totals.droppedChannelCount
        report.decodedByteCount = discardedBytes + consumed
        report.inputByteCount = inputByteCount
    }

    /// Adds the problems found at the end of the input, after every record.
    private mutating func finishReport(endProblems: [XMLTVError.Kind]) {
        isEnded = true
        let end = discardedBytes + window.count
        let line = discardedNewlines + (window.bytes.baseAddress.map { ByteSearch.countNewlines(in: $0, from: 0, end: window.count) } ?? 0) + 1
        for kind in endProblems {
            report.add(
                XMLTVDiagnostic(kind: kind, recovery: Diagnostics.recoveryAtEnd(kind), byteOffset: end, line: line),
                limit: options.diagnosticLimit)
        }
        report.decodedByteCount = end
        report.inputByteCount = inputByteCount
    }

    private func located(_ error: XMLTVError) -> XMLTVError {
        var error = error
        let bytes = window.bytes
        let offset = min(error.byteOffset, bytes.count)
        if let base = bytes.baseAddress {
            error.line = discardedNewlines + ByteSearch.countNewlines(in: base, from: 0, end: offset) + 1
            // With no line end before the offset in the window, the line began in discarded input.
            let lineStart = ByteSearch.lineStart(of: offset, in: base)
            error.column = offset - lineStart + (lineStart == 0 ? discardedColumn : 0) + 1
        }
        error.byteOffset = discardedBytes + offset
        return error
    }
}
