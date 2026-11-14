import CZlib

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

    /// Inflates all of `input`, appending the output to `output`.
    func inflate(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer) throws(XMLTVError) {
        guard !ignoresRemainingInput, var rest = input.baseAddress.map({ UnsafeBufferPointer(start: $0, count: input.count) }) else { return }
        if let first = pendingMagicByte {
            guard let second = rest.first else { return }
            pendingMagicByte = nil
            guard first == 0x1F && second == 0x8B else { ignoresRemainingInput = true; return }
            try startNextMember()
            let magic: [UInt8] = [first]
            try magic.withUnsafeBufferPointer { magic throws(XMLTVError) in try feed(magic, into: &output) }
        }
        // zlib counts input in 32-bit units, so very large inputs go in slices.
        while !rest.isEmpty && !ignoresRemainingInput {
            let slice = UnsafeBufferPointer(rebasing: rest.prefix(Int(UInt32.max)))
            try feed(slice, into: &output)
            rest = UnsafeBufferPointer(rebasing: rest.dropFirst(slice.count))
        }
    }

    private func feed(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer) throws(XMLTVError) {
        stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress!)
        stream.pointee.avail_in = UInt32(input.count)

        while true {
            if isAtMemberEnd {
                switch stream.pointee.avail_in {
                case 0:
                    return
                case 1:
                    pendingMagicByte = stream.pointee.next_in[0]
                    stream.pointee.avail_in = 0
                    return
                default:
                    guard stream.pointee.next_in[0] == 0x1F, stream.pointee.next_in[1] == 0x8B else {
                        ignoresRemainingInput = true
                        stream.pointee.avail_in = 0
                        return
                    }
                    try startNextMember()
                }
            }
            let space = output.unusedCapacity(atLeast: 256 << 10)
            let writable = min(space.count, Int(UInt32.max))
            stream.pointee.next_out = space.baseAddress
            stream.pointee.avail_out = UInt32(writable)

            let status = CZlib.inflate(stream, Z_NO_FLUSH)
            output.commit(writable - Int(stream.pointee.avail_out))
            switch status {
            case Z_STREAM_END:
                isAtMemberEnd = true
            case Z_OK:
                // Done with this input once it is consumed and zlib had output space to spare,
                // so it holds nothing back.
                if stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0 { return }
            case Z_BUF_ERROR:
                return
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
    /// a hint.
    ///
    /// Returns nil, or the problem if the data was truncated or corrupt. Everything decompressed
    /// before the problem is in `output`; the caller decides whether the problem is fatal.
    static func inflateAll(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer) throws(XMLTVError) -> XMLTVError.Kind? {
        if input.count >= 18 {
            let trailer = input.count - 4
            let isize = Int(input[trailer]) | Int(input[trailer + 1]) << 8 | Int(input[trailer + 2]) << 16 | Int(input[trailer + 3]) << 24
            _ = output.unusedCapacity(atLeast: max(isize, input.count) + 1)
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
