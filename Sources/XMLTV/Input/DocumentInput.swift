import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Produces a whole document as one contiguous UTF-8 buffer, the form the parallel driver
/// needs. Copies are avoided where possible:
/// - UTF-8 `Data`, or a memory-mapped UTF-8 file, is parsed in place.
/// - A read file is read once into a buffer of its exact size.
/// - Gzip and non-UTF-8 input each cost exactly one conversion pass.
enum DocumentInput {
    /// What happened on the way to UTF-8.
    struct InputInfo {
        var encoding: XMLTVEncoding
        /// Problems recovered in lenient mode: a truncated or corrupt gzip stream, or malformed
        /// input in the source encoding. They are reported as diagnostics at the end of the
        /// document.
        var problems: [XMLTVError.Kind] = []
        /// The size of the input before decompression and transcoding.
        var inputByteCount = 0
    }

    static func withUTF8<R>(
        contentsOf url: URL, options: XMLTVOptions,
        _ body: (UnsafeBufferPointer<UInt8>, InputInfo) throws(XMLTVError) -> R
    ) throws(XMLTVError) -> R {
        guard url.isFileURL else { throw XMLTVError(.notAFileURL(url.absoluteString)) }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw XMLTVError(.io(operation: "open", path: url.path, errno: errno)) }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw XMLTVError(.io(operation: "stat", path: url.path, errno: errno)) }
        let size = Int(info.st_size)

        if options.fileAccess == .memoryMapped && size > 0 {
            guard let mapping = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), mapping != MAP_FAILED else {
                throw XMLTVError(.io(operation: "mmap", path: url.path, errno: errno))
            }
            defer { munmap(mapping, size) }
            _ = madvise(mapping, size, MADV_WILLNEED)
            let bytes = UnsafeBufferPointer(start: mapping.assumingMemoryBound(to: UInt8.self), count: size)
            return try withUTF8(bytes, options: options, body)
        }

        let contents = try readAll(descriptor, sizeHint: size, path: url.path)
        return try withUTF8(contents.bytes, options: options, body)
    }

    static func withUTF8<R>(
        data: Data, options: XMLTVOptions,
        _ body: (UnsafeBufferPointer<UInt8>, InputInfo) throws(XMLTVError) -> R
    ) throws(XMLTVError) -> R {
        // `Data.withUnsafeBytes` rethrows untyped errors. The error is carried out in a Result
        // so the typed signature is kept.
        let result: Result<R, XMLTVError> = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            do throws(XMLTVError) {
                return .success(try withUTF8(bytes, options: options, body))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Decompresses and transcodes as needed, then calls `body` with UTF-8 bytes with any BOM
    /// removed.
    static func withUTF8<R>(
        _ raw: UnsafeBufferPointer<UInt8>, options: XMLTVOptions,
        _ body: (UnsafeBufferPointer<UInt8>, InputInfo) throws(XMLTVError) -> R
    ) throws(XMLTVError) -> R {
        if GzipInflater.isGzip(raw) {
            var inflated = ByteBuffer()
            let problem = try GzipInflater.inflateAll(raw, into: &inflated)
            if let problem, options.policy == .strict { throw XMLTVError(problem) }
            // Decompressed once only: gzip inside gzip is not XMLTV, as the streaming driver also
            // decides.
            return try transcoded(inflated.bytes, options: options) { bytes, info throws(XMLTVError) in
                var info = info
                info.inputByteCount = raw.count
                // Compression problems come before encoding ones, as the streaming driver finds
                // them, so both report the same order.
                if let problem { info.problems.insert(problem, at: 0) }
                return try body(bytes, info)
            }
        }
        return try transcoded(raw, options: options, body)
    }

    /// Detects the encoding of uncompressed bytes and transcodes them to UTF-8 if needed.
    private static func transcoded<R>(
        _ raw: UnsafeBufferPointer<UInt8>, options: XMLTVOptions,
        _ body: (UnsafeBufferPointer<UInt8>, InputInfo) throws(XMLTVError) -> R
    ) throws(XMLTVError) -> R {
        let (encoding, bomLength) = try EncodingDetector.detect(raw, override: options.encoding)
        let content = UnsafeBufferPointer(rebasing: raw[bomLength...])
        if encoding == .utf8 { return try body(content, InputInfo(encoding: .utf8, inputByteCount: raw.count)) }

        var transcoder = Transcoder(encoding)
        var output = ByteBuffer(capacity: content.count + content.count / 4)
        transcoder.transcode(content, into: &output, isFinal: true)
        var info = InputInfo(encoding: encoding, inputByteCount: raw.count)
        if transcoder.replacedInvalidInput {
            if options.policy == .strict { throw XMLTVError(.invalidEncoding) }
            info.problems.append(.invalidEncoding)
        }
        return try body(output.bytes, info)
    }

    /// Reads the whole file into one buffer. Large files are read with several `pread`s at
    /// once: the cost is mostly page faults on the fresh buffer, and those scale with threads.
    /// The serial loop afterwards picks up anything appended since `fstat`.
    static func readAll(_ descriptor: Int32, sizeHint: Int, path: String) throws(XMLTVError) -> ByteBuffer {
        var buffer = ByteBuffer(capacity: sizeHint + 1)
        if sizeHint >= parallelReadThreshold {
            let space = buffer.unusedCapacity(atLeast: sizeHint)
            let target = UncheckedSendable(space.baseAddress!)
            let sliceCount = 8
            let sliceSize = (sizeHint + sliceCount - 1) / sliceCount
            let failures = UncheckedSendable(UnsafeMutableBufferPointer<Int32>.allocate(capacity: sliceCount))
            failures.value.initialize(repeating: 0)
            defer { failures.value.deallocate() }
            DispatchQueue.concurrentPerform(iterations: sliceCount) { slice in
                var offset = slice * sliceSize
                let end = min(sizeHint, offset + sliceSize)
                while offset < end {
                    let n = pread(descriptor, target.value + offset, end - offset, off_t(offset))
                    if n > 0 { offset += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    failures.value[slice] = n < 0 ? errno : EIO   // EIO: the file shrank under us
                    return
                }
            }
            if let error = failures.value.first(where: { $0 != 0 }) {
                throw XMLTVError(.io(operation: "read", path: path, errno: error))
            }
            buffer.commit(sizeHint)
            guard lseek(descriptor, off_t(sizeHint), SEEK_SET) >= 0 else {
                throw XMLTVError(.io(operation: "seek", path: path, errno: errno))
            }
        }
        while true {
            // The buffer is one byte larger than the file, so the final zero-length read
            // never forces it to grow and copy.
            let space = buffer.unusedCapacity(atLeast: 1)
            let n = read(descriptor, space.baseAddress, space.count)
            if n == 0 { return buffer }
            if n < 0 {
                if errno == EINTR { continue }
                throw XMLTVError(.io(operation: "read", path: path, errno: errno))
            }
            buffer.commit(n)
        }
    }

    static let parallelReadThreshold = 64 << 20
}
