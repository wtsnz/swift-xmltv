/// Works out the document's encoding from its first bytes, as XML 1.0 Appendix F describes:
/// a byte-order mark, the byte pattern of `<?xml` in UTF-16, or else the `encoding="…"` of the XML
/// declaration. Undeclared documents are UTF-8.
enum EncodingDetector {
    /// The encoding, and how many leading bytes (a BOM) to drop.
    /// With an `override`, only the BOM is examined: the declared name is not consulted, so a
    /// feed that declares an unknown or wrong encoding can still be read.
    static func detect(
        _ bytes: UnsafeBufferPointer<UInt8>, override: XMLTVEncoding? = nil
    ) throws(XMLTVError) -> (encoding: XMLTVEncoding, bomLength: Int) {
        func starts(with prefix: [UInt8]) -> Bool {
            bytes.count >= prefix.count && zip(bytes, prefix).allSatisfy { $0 == $1 }
        }
        let bom: (XMLTVEncoding, Int)? =
            starts(with: [0xEF, 0xBB, 0xBF]) ? (.utf8, 3)
            : starts(with: [0xFF, 0xFE]) ? (.utf16LittleEndian, 2)
            : starts(with: [0xFE, 0xFF]) ? (.utf16BigEndian, 2)
            : nil
        if let override { return (override, bom?.1 ?? 0) }
        if let bom { return bom }
        if starts(with: [0x3C, 0x00, 0x3F, 0x00]) { return (.utf16LittleEndian, 0) }
        if starts(with: [0x00, 0x3C, 0x00, 0x3F]) { return (.utf16BigEndian, 0) }
        if bytes.count >= declarationLimit, bytes.starts(with: "<?xml".utf8),
           indexOf("?>", in: bytes.prefix(declarationLimit)) == nil {
            throw XMLTVError(.malformedMarkup("the XML declaration is longer than 64 KiB"))
        }
        guard let declared = declaredEncoding(bytes) else { return (.utf8, 0) }
        switch try encoding(named: declared) {
        case .utf16LittleEndian, .utf16BigEndian:
            // The declaration was just read as ASCII, so the document is not in UTF-16, which
            // would have shown as a BOM or as the UTF-16 pattern of `<?xml` above. Writers that
            // save a string as UTF-8 but keep the declaration it was made with, such as .NET's
            // `StringWriter`, produce this. libxml2 reads it as UTF-8, and so does this.
            return (.utf8, 0)
        case let encoding:
            return (encoding, 0)
        }
    }

    /// How far to look for the end of the XML declaration. A declaration may contain any amount
    /// of whitespace, so this is generous rather than tight; real ones are under 100 bytes.
    static let declarationLimit = 64 << 10

    /// Whether `bytes` is enough of the document's start to detect its encoding: a BOM or UTF-16
    /// pattern, or a complete XML declaration, or no declaration at all.
    static func canDetect(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        if bytes.count >= declarationLimit { return true }
        guard bytes.count >= 5 else { return false }
        let start = bytes.first == 0xEF ? 3 : 0
        guard bytes.count >= start + 5 else { return false }
        if !bytes[start..<(start + 5)].elementsEqual("<?xml".utf8) { return true }
        return indexOf("?>", in: bytes[...]) != nil
    }

    /// Maps an IANA charset name to a supported encoding.
    static func encoding(named name: String) throws(XMLTVError) -> XMLTVEncoding {
        switch name.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii":
            return .utf8
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "iso_8859-1:1987", "latin1", "latin-1", "l1",
             "cp819", "ibm819", "iso-ir-100", "csisolatin1":
            return .latin1
        case "iso-8859-15", "iso8859-15", "iso_8859-15", "latin-9", "latin9", "csisolatin9":
            return .latin9
        case "windows-1252", "windows1252", "cp1252", "x-cp1252", "cswindows1252":
            return .windows1252
        case "utf-16le":
            return .utf16LittleEndian
        case "utf-16be", "utf-16":
            return .utf16BigEndian
        default:
            throw XMLTVError(.unsupportedEncoding(name))
        }
    }

    /// The value of `encoding` in a leading `<?xml … ?>` declaration, if there is one.
    private static func declaredEncoding(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        let prefix = bytes.prefix(declarationLimit)
        guard prefix.starts(with: "<?xml".utf8) else { return nil }
        guard let close = indexOf("?>", in: prefix) else { return nil }
        let declaration = prefix[..<close]
        guard let keyword = indexOf("encoding", in: declaration) else { return nil }
        var i = keyword + 8
        while i < close && (prefix[i].isXMLWhitespace || prefix[i] == UInt8(ascii: "=")) { i += 1 }
        guard i < close, prefix[i] == UInt8(ascii: "\"") || prefix[i] == UInt8(ascii: "'") else { return nil }
        let quote = prefix[i]
        let start = i + 1
        guard let end = prefix[start..<close].firstIndex(of: quote) else { return nil }
        return String(decoding: prefix[start..<end], as: UTF8.self)
    }

    private static func indexOf(_ needle: String, in haystack: Slice<UnsafeBufferPointer<UInt8>>) -> Int? {
        let needle = Array(needle.utf8)
        guard haystack.count >= needle.count else { return nil }
        var i = haystack.startIndex
        while i + needle.count <= haystack.endIndex {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}

/// Converts input in a supported encoding to UTF-8, one chunk at a time.
///
/// Single-byte encodings need no state between chunks. UTF-16 carries an odd trailing byte and
/// an unpaired high surrogate into the next chunk. Malformed UTF-16 becomes U+FFFD, and
/// ``replacedInvalidInput`` records that it happened.
struct Transcoder {
    let encoding: XMLTVEncoding
    private(set) var replacedInvalidInput = false
    private var pendingByte: UInt8?
    private var pendingHighSurrogate: UInt16?

    init(_ encoding: XMLTVEncoding) {
        self.encoding = encoding
    }

    mutating func transcode(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer, isFinal: Bool) {
        switch encoding {
        case .utf8:
            output.append(input)
        case .latin1, .latin9, .windows1252:
            transcodeSingleByte(input, into: &output)
        case .utf16LittleEndian, .utf16BigEndian:
            transcodeUTF16(input, into: &output, isFinal: isFinal)
        }
    }

    // MARK: Single-byte encodings

    private func transcodeSingleByte(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer) {
        guard let base = input.baseAddress else { return }
        var i = 0
        let count = input.count
        // ASCII runs are copied 16 bytes at a time. Most XMLTV markup and text is ASCII.
        while i < count {
            var runEnd = i
            while runEnd + 16 <= count {
                let block = ByteSearch.load(base, runEnd)
                if ByteSearch.nibbleMask(block .>= SIMD16(repeating: 0x80)) != 0 { break }
                runEnd += 16
            }
            while runEnd < count && base[runEnd] < 0x80 { runEnd += 1 }
            if runEnd > i { output.append(UnsafeBufferPointer(start: base + i, count: runEnd - i)) }
            i = runEnd
            if i < count {
                appendUTF8(scalarValue(singleByte: base[i]), to: &output)
                i += 1
            }
        }
    }

    private func scalarValue(singleByte byte: UInt8) -> UInt32 {
        switch encoding {
        case .latin9:
            switch byte {
            case 0xA4: return 0x20AC
            case 0xA6: return 0x0160
            case 0xA8: return 0x0161
            case 0xB4: return 0x017D
            case 0xB8: return 0x017E
            case 0xBC: return 0x0152
            case 0xBD: return 0x0153
            case 0xBE: return 0x0178
            default: return UInt32(byte)
            }
        case .windows1252 where (0x80...0x9F).contains(byte):
            return Transcoder.windows1252High[Int(byte - 0x80)]
        default:
            return UInt32(byte)
        }
    }

    /// Windows-1252 bytes 0x80 to 0x9F. The five undefined bytes map to the C1 controls of the same
    /// value, as WHATWG specifies.
    private static let windows1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    // MARK: UTF-16

    private mutating func transcodeUTF16(_ input: UnsafeBufferPointer<UInt8>, into output: inout ByteBuffer, isFinal: Bool) {
        let littleEndian = encoding == .utf16LittleEndian
        var i = 0
        func nextUnit(_ first: UInt8, _ second: UInt8) -> UInt16 {
            littleEndian ? UInt16(first) | UInt16(second) << 8 : UInt16(first) << 8 | UInt16(second)
        }
        var units: [UInt16] = []
        units.reserveCapacity(input.count / 2 + 1)
        if let pending = pendingByte, !input.isEmpty {
            units.append(nextUnit(pending, input[0]))
            pendingByte = nil
            i = 1
        }
        while i + 1 < input.count {
            units.append(nextUnit(input[i], input[i + 1]))
            i += 2
        }
        if i < input.count { pendingByte = input[i] }

        for unit in units {
            if let high = pendingHighSurrogate {
                pendingHighSurrogate = nil
                if UTF16.isTrailSurrogate(unit) {
                    let scalar = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
                    appendUTF8(scalar, to: &output)
                    continue
                }
                appendReplacement(to: &output)
            }
            if UTF16.isLeadSurrogate(unit) {
                pendingHighSurrogate = unit
            } else if UTF16.isTrailSurrogate(unit) {
                appendReplacement(to: &output)
            } else {
                appendUTF8(UInt32(unit), to: &output)
            }
        }

        if isFinal {
            if pendingHighSurrogate != nil || pendingByte != nil { appendReplacement(to: &output) }
            pendingHighSurrogate = nil
            pendingByte = nil
        }
    }

    private mutating func appendReplacement(to output: inout ByteBuffer) {
        replacedInvalidInput = true
        appendUTF8(0xFFFD, to: &output)
    }

    private func appendUTF8(_ scalar: UInt32, to output: inout ByteBuffer) {
        switch scalar {
        case 0..<0x80:
            output.append(UInt8(scalar))
        case 0x80..<0x800:
            output.append(UInt8(0xC0 | scalar >> 6))
            output.append(UInt8(0x80 | scalar & 0x3F))
        case 0x800..<0x10000:
            output.append(UInt8(0xE0 | scalar >> 12))
            output.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            output.append(UInt8(0x80 | scalar & 0x3F))
        default:
            output.append(UInt8(0xF0 | scalar >> 18))
            output.append(UInt8(0x80 | scalar >> 12 & 0x3F))
            output.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            output.append(UInt8(0x80 | scalar & 0x3F))
        }
    }
}
