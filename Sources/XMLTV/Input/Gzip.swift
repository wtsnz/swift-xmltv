internal import CZlib

/// Streaming gzip decompression with system zlib. Concatenated members, as `cat a.gz b.gz`
/// produces, are decompressed one after another. Bytes after the last member that do not
/// start another member, often zero padding, are ignored, as gzip(1) ignores them.
///
/// Inflate is single-threaded and runs at about 2.5 GB/s of output. That is slower than the
/// parallel parser, so for `.xml.gz` input decompression sets the overall speed.
final class GzipInflater {
    /// zlib keeps a back-pointer to its `z_stream`, so the stream needs a stable address.
    private let stream: UnsafeMutablePointer<z_stream>
    /// Whether the last member ended cleanly, with nothing after it so far.
    private(set) var isAtMemberEnd = false
    /// The first byte after a member end, when the input ran out before the second byte showed
    /// whether another member follows.
    private var pendingMagicByte: UInt8?
    private var ignoresRemainingInput = false

    static func isGzip(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        bytes.count >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B
    }

    init() throws(XMLTVError) {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        // 15 window bits + 16 selects gzip framing only.
        let status = inflateInit2_(stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            stream.deallocate()
            throw XMLTVError(.invalidCompressedData("zlib initialisation failed (\(status))"))
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    /// True when the input so far is complete gzip data: every member ended with a valid trailer.
    var isComplete: Bool { isAtMemberEnd || ignoresRemainingInput }

    /// Inflates from the front of `input`, appending to `output`, until the input is used up or
    /// at least `limit` bytes have been written. Returns how many input bytes were consumed; the
    /// caller passes the rest again later. A limit keeps a streaming reader's memory bounded
    /// however well the data compresses: deflate can expand about 1,000 times.
    ///
    /// After a call that stopped at the limit, ``hasHeldOutput`` is true: zlib may hold output
    /// for input it has consumed, so call again, with empty input if there is no more.
    @discardableResult
    func inflate(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer, limit: Int = .max) throws(XMLTVError) -> Int {
        guard !ignoresRemainingInput else { return input.count }
        guard !input.isEmpty || hasHeldOutput else { return 0 }
        hasHeldOutput = false
        let start = output.count
        var rest = input
        if let first = pendingMagicByte {
            guard let second = rest.first else { return 0 }
            pendingMagicByte = nil
            guard first == 0x1F && second == 0x8B else { ignoresRemainingInput = true; return input.count }
            try startNextMember()
            let magic: [UInt8] = [first]
            try magic.withUnsafeBufferPointer { magic throws(XMLTVError) in
                _ = try feed(magic, into: &output, limit: .max)
            }
        }
        // zlib counts input in 32-bit units, so very large inputs go in slices. On 32-bit
        // platforms such as watchOS, `Int` cannot hold `UInt32.max`, so the limit is clamped.
        repeat {
            let slice = UnsafeBufferPointer(rebasing: rest.prefix(Int(clamping: UInt32.max)))
            let used = try feed(slice, into: &output, limit: limit - (output.count - start))
            rest = UnsafeBufferPointer(rebasing: rest.dropFirst(used))
        } while !rest.isEmpty && !ignoresRemainingInput && !hasHeldOutput
        return ignoresRemainingInput ? input.count : input.count - rest.count
    }

    /// Whether the last call to ``inflate(_:into:limit:)`` stopped at its limit.
    private(set) var hasHeldOutput = false

    /// Feeds one slice to zlib. Returns how much of it was consumed, which is all of it unless
    /// `limit` output bytes were written first.
    private func feed(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer, limit: Int) throws(XMLTVError) -> Int {
        stream.pointee.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
        stream.pointee.avail_in = UInt32(input.count)
        var written = 0
        var consumed: Int { input.count - Int(stream.pointee.avail_in) }

        while true {
            if isAtMemberEnd {
                switch stream.pointee.avail_in {
                case 0:
                    return input.count
                case 1:
                    pendingMagicByte = stream.pointee.next_in[0]
                    stream.pointee.avail_in = 0
                    return input.count
                default:
                    guard stream.pointee.next_in[0] == 0x1F, stream.pointee.next_in[1] == 0x8B else {
                        ignoresRemainingInput = true
                        stream.pointee.avail_in = 0
                        return input.count
                    }
                    try startNextMember()
                }
            }
            guard written < limit else {
                hasHeldOutput = true
                return consumed
            }
            let space = output.unusedCapacity(atLeast: min(256 << 10, limit - written))
            let writable = min(space.count, Int(clamping: UInt32.max), limit - written)
            stream.pointee.next_out = space.baseAddress
            stream.pointee.avail_out = UInt32(writable)

            let status = CZlib.inflate(stream, Z_NO_FLUSH)
            let produced = writable - Int(stream.pointee.avail_out)
            output.commit(produced)
            written += produced
            switch status {
            case Z_STREAM_END:
                isAtMemberEnd = true
            case Z_OK:
                // Done with this input once it is consumed and zlib had output space to spare,
                // so it holds nothing back.
                if stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0 { return consumed }
            case Z_BUF_ERROR:
                return consumed
            default:
                let message = stream.pointee.msg.map { String(cString: $0) } ?? "status \(status)"
                throw XMLTVError(.invalidCompressedData(message))
            }
        }
    }

    private func startNextMember() throws(XMLTVError) {
        guard inflateReset(stream) == Z_OK else { throw XMLTVError(.invalidCompressedData("reset failed")) }
        isAtMemberEnd = false
    }

    /// Decompresses a complete in-memory gzip file into `output`, which should be empty. The
    /// output is pre-sized from the trailer's ISIZE field: the uncompressed size mod 2³², so only
    /// a hint. In a truncated file those four bytes are compressed data, so the hint is capped
    /// at 40 times the input, well above the 6 to 11 times that XMLTV compresses by; growth
    /// covers anything larger.
    ///
    /// Returns nil, or the problem if the data was truncated or corrupt. Everything decompressed
    /// before the problem is in `output`; the caller decides whether the problem is fatal.
    static func inflateAll(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer) throws(XMLTVError) -> XMLTVError.Kind? {
        if input.count >= 18 {
            let trailer = input.count - 4
            let isize = UInt32(input[trailer]) | UInt32(input[trailer + 1]) << 8
                | UInt32(input[trailer + 2]) << 16 | UInt32(input[trailer + 3]) << 24
            let cap = input.count.multipliedReportingOverflow(by: 40)
            let hint = min(Int(clamping: isize), cap.overflow ? .max : cap.partialValue)
            _ = output.unusedCapacity(atLeast: max(hint, input.count) &+ 1)
        }
        let inflater = try GzipInflater()
        do throws(XMLTVError) {
            try inflater.inflate(input, into: &output)
        } catch {
            return error.kind
        }
        return inflater.isComplete ? nil : .invalidCompressedData("truncated gzip stream")
    }
}
