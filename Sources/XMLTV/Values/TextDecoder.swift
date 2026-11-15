/// Turns raw text and attribute ranges into Swift strings.
///
/// The common case allocates at most once. The text has no `&` and no CR, so after trimming
/// the range is validated and copied once into a `String`. Repeated values come from the
/// ``Interner`` with no copy at all. Only flagged ranges go through the decoding buffer.
///
/// Semantics follow XML 1.0 and the upstream XMLTV tools:
/// - The five predefined entities and decimal or hexadecimal character references are decoded
///   once, so `&amp;amp;` becomes `&amp;`.
/// - A literal CRLF or CR becomes LF.
/// - In attribute values, literal tab, LF and CR become a space.
/// - Element text is trimmed of leading and trailing XML whitespace, after references are
///   decoded. Inner whitespace, including newlines, is kept, as `tv_cat` keeps it.
struct TextDecoder {
    enum Mode { case text, attribute, cdata }

    var interner: Interner

    init(internerBudget: Int = Interner.documentArenaBudget) {
        interner = Interner(arenaBudget: internerBudget)
    }
    /// Reused output buffer for decoded or multi-piece text.
    private var scratch: [UInt8] = []
    /// Whether every piece gathered since ``beginPieces()`` was free of problems.
    private var piecesAreClean = true

    // Problems in text are reported where they are in the source. Text that is decoded first is
    // checked on its source bytes: decoding neither adds a problem, since a reference to a
    // forbidden character is refused, nor removes one, since every other byte passes through,
    // so nothing is missed and the decoded string is not checked again.

    // MARK: Single ranges

    /// The trimmed string for an element's text content.
    @inline(__always)
    mutating func text(
        _ range: ByteRange, needsDecoding: Bool, in scanner: XMLScanner,
        diagnostics: inout Diagnostics
    ) throws(XMLTVError) -> String {
        let trimmed = trim(range, in: scanner)
        if !needsDecoding {
            return try string(scanner.pointer(to: trimmed), at: trimmed.start, diagnostics: &diagnostics)
        }
        // References can decode to whitespace (`&#13;` at the end of a description is common), so
        // the decoded text is trimmed again, as the upstream XMLTV tools do. One range needs no
        // repair of its own: making the string replaces invalid UTF-8.
        scratch.removeAll(keepingCapacity: true)
        try decode(trimmed, mode: .text, in: scanner, diagnostics: &diagnostics)
        return try decoded(trimmedScratch(), from: scanner.pointer(to: trimmed), at: trimmed.start, diagnostics: &diagnostics)
    }

    /// The string for an attribute value. Values are not trimmed: XML keeps their whitespace.
    @inline(__always)
    mutating func attribute(
        _ attribute: RawAttribute, in scanner: XMLScanner, diagnostics: inout Diagnostics
    ) throws(XMLTVError) -> String {
        let range = attribute.value
        if !attribute.needsDecoding {
            return try string(scanner.pointer(to: range), at: range.start, diagnostics: &diagnostics)
        }
        scratch.removeAll(keepingCapacity: true)
        try decode(range, mode: .attribute, in: scanner, diagnostics: &diagnostics)
        return try decoded(0..<scratch.count, from: scanner.pointer(to: range), at: range.start, diagnostics: &diagnostics)
    }

    /// Decodes an attribute value into the scratch buffer and passes the bytes to `body` without
    /// creating a String. Timestamps and numbers use this.
    @inline(__always)
    mutating func withAttributeBytes<R>(
        _ attribute: RawAttribute, in scanner: XMLScanner, diagnostics: inout Diagnostics,
        _ body: (UnsafeBufferPointer<UInt8>) -> R
    ) throws(XMLTVError) -> R {
        if !attribute.needsDecoding { return body(scanner.pointer(to: attribute.value)) }
        scratch.removeAll(keepingCapacity: true)
        try decode(attribute.value, mode: .attribute, in: scanner, diagnostics: &diagnostics)
        return scratch.withUnsafeBufferPointer(body)
    }

    // MARK: Multi-piece text

    /// Text split by comments or CDATA sections, or interleaved with child elements as in
    /// credits, is gathered piece by piece and trimmed once at the end.
    mutating func beginPieces() {
        scratch.removeAll(keepingCapacity: true)
        piecesAreClean = true
    }

    /// Each piece is checked on its own, and invalid UTF-8 in it is repaired there: bytes on
    /// either side of a comment or a child element must not join into one character.
    mutating func appendPiece(
        _ range: ByteRange, mode: Mode, needsDecoding: Bool, in scanner: XMLScanner, diagnostics: inout Diagnostics
    ) throws(XMLTVError) {
        let pieceStart = scratch.count
        if needsDecoding || mode == .cdata {
            try decode(range, mode: mode, in: scanner, diagnostics: &diagnostics)
        } else {
            scratch.append(contentsOf: scanner.pointer(to: range))
        }
        guard try !Self.check(scanner.pointer(to: range), at: range.start, diagnostics: &diagnostics) else { return }
        piecesAreClean = false
        let repaired: String? = scratch.withUnsafeBufferPointer { buffer in
            let piece = UnsafeBufferPointer(rebasing: buffer[pieceStart...])
            let decoded = String(decoding: piece, as: UTF8.self)
            return decoded.utf8.elementsEqual(piece) ? nil : decoded
        }
        if let repaired { scratch.replaceSubrange(pieceStart..., with: repaired.utf8) }
    }

    /// The gathered text, trimmed. Its problems were reported as the pieces were added.
    mutating func finishPieces() -> String {
        unchecked(trimmedScratch(), isClean: piecesAreClean)
    }

    /// The scratch buffer without leading and trailing XML whitespace.
    private func trimmedScratch() -> Range<Int> {
        var start = 0, end = scratch.count
        while start < end && scratch[start].isXMLWhitespace { start &+= 1 }
        while end > start && scratch[end &- 1].isXMLWhitespace { end &-= 1 }
        return start..<end
    }

    // MARK: String creation

    /// A string from part of the scratch buffer, decoded from `source`, which starts at `offset`.
    /// The source is checked only when the string is not in the table yet: only clean strings
    /// are cached, and decoding neither adds nor removes a problem, so a cached string's source
    /// was clean too. Repeated text with references then costs no validation, as plain text
    /// does not.
    private mutating func decoded(
        _ range: Range<Int>, from source: UnsafeBufferPointer<UInt8>, at offset: Int, diagnostics: inout Diagnostics
    ) throws(XMLTVError) -> String {
        // Read through a local reference so the buffer access does not overlap the mutating
        // interner insert.
        let bytes = scratch
        return try bytes.withUnsafeBufferPointer { buffer throws(XMLTVError) in
            let text = UnsafeBufferPointer(rebasing: buffer[range])
            guard Interner.isEligible(text.count) else {
                _ = try Self.check(source, at: offset, diagnostics: &diagnostics)
                return String(decoding: text, as: UTF8.self)
            }
            return try interner.string(for: text) { text throws(XMLTVError) in
                let isClean = try Self.check(source, at: offset, diagnostics: &diagnostics)
                return (String(decoding: text, as: UTF8.self), isClean)
            }
        }
    }

    /// A string from part of the scratch buffer, which has already been checked.
    private mutating func unchecked(_ range: Range<Int>, isClean: Bool) -> String {
        // Read through a local reference so the buffer access does not overlap the mutating
        // interner insert.
        let bytes = scratch
        return bytes.withUnsafeBufferPointer { buffer in
            let text = UnsafeBufferPointer(rebasing: buffer[range])
            guard Interner.isEligible(text.count) else { return String(decoding: text, as: UTF8.self) }
            return interner.string(for: text) { text in (String(decoding: text, as: UTF8.self), isClean) }
        }
    }

    @inline(__always)
    private mutating func string(
        _ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, diagnostics: inout Diagnostics
    ) throws(XMLTVError) -> String {
        if Interner.isEligible(bytes.count) {
            return try interner.string(for: bytes) { bytes throws(XMLTVError) in
                try TextDecoder.validatedString(bytes, at: offset, diagnostics: &diagnostics)
            }
        }
        return try TextDecoder.validatedString(bytes, at: offset, diagnostics: &diagnostics).value
    }

    /// Checks the text once, then creates the string. Invalid UTF-8 is repaired with U+FFFD, and
    /// characters XML forbids are kept. Either is a diagnostic in lenient mode and an error in
    /// strict mode, reported where it is. `isCacheable` is false when a diagnostic was reported.
    @inline(__always)
    static func validatedString(
        _ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, diagnostics: inout Diagnostics
    ) throws(XMLTVError) -> (value: String, isCacheable: Bool) {
        let isClean = try check(bytes, at: offset, diagnostics: &diagnostics)
        return (String(decoding: bytes, as: UTF8.self), isClean)
    }

    /// Reports each kind of problem in source text that starts at `offset`, at the problem's own
    /// position. Returns whether the text was clean.
    @inline(__always)
    static func check(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, diagnostics: inout Diagnostics) throws(XMLTVError) -> Bool {
        guard TextValidation.firstProblem(in: bytes) != nil else { return true }
        // Invalid UTF-8 is replaced as the string is made. A forbidden character is kept.
        for (kind, index) in TextValidation.problems(in: bytes) {
            try diagnostics.report(kind, kind == .invalidUTF8 ? .repaired : .keptAsWritten, at: offset &+ index)
        }
        return false
    }

    // MARK: Decoding

    @inline(__always)
    private func trim(_ range: ByteRange, in scanner: XMLScanner) -> ByteRange {
        var start = range.start, end = range.end
        while start < end && scanner.byte(start).isXMLWhitespace { start &+= 1 }
        while end > start && scanner.byte(end &- 1).isXMLWhitespace { end &-= 1 }
        return ByteRange(start: start, end: end)
    }

    /// Appends the decoded form of `range` to `scratch`.
    ///
    /// Decoding never makes text longer: every reference is at least as long as the UTF-8 it
    /// stands for, and line-end normalisation only removes bytes. So the output is written
    /// through a pointer into space reserved up front, and the unused tail is dropped afterwards.
    private mutating func decode(
        _ range: ByteRange, mode: Mode, in scanner: XMLScanner, diagnostics: inout Diagnostics
    ) throws(XMLTVError) {
        let outputStart = scratch.count
        scratch.append(contentsOf: repeatElement(0, count: range.count))
        var unsupported: [Int] = []
        let written = scratch.withUnsafeMutableBufferPointer { buffer in
            let output = buffer.baseAddress! + outputStart
            var o = 0
            var i = range.start
            while i < range.end {
                let byte = scanner.byte(i)
                switch byte {
                case UInt8(ascii: "&") where mode != .cdata:
                    let (next, ok) = TextDecoder.decodeReference(at: i, end: range.end, in: scanner, into: output, at: &o)
                    if !ok { unsupported.append(i) }
                    i = next
                    continue
                case 0x0D:
                    // CRLF and lone CR both become one line feed (one space in attributes).
                    output[o] = mode == .attribute ? 0x20 : 0x0A
                    if i &+ 1 < range.end && scanner.byte(i &+ 1) == 0x0A { i &+= 1 }
                case 0x09 where mode == .attribute, 0x0A where mode == .attribute:
                    output[o] = 0x20
                default:
                    output[o] = byte
                }
                o &+= 1
                i &+= 1
            }
            return o
        }
        scratch.removeLast(range.count &- written)
        for offset in unsupported {
            try diagnostics.report(.unsupportedEntity(TextDecoder.referenceText(at: offset, end: range.end, in: scanner)), .keptAsWritten, at: offset)
        }
    }

    /// Decodes the reference at the `&` at `start`, writing its UTF-8 to `output[o...]`.
    /// Returns the index after it and whether it was a supported reference. An unsupported one
    /// is copied through literally.
    @inline(__always)
    private static func decodeReference(
        at start: Int, end: Int, in scanner: XMLScanner, into output: UnsafeMutablePointer<UInt8>, at o: inout Int
    ) -> (next: Int, ok: Bool) {
        let semicolon = referenceEnd(at: start, end: end, in: scanner)
        guard semicolon < end else {
            output[o] = UInt8(ascii: "&")
            o &+= 1
            return (start &+ 1, false)
        }

        if let scalar = referencedScalar(ByteRange(start: start &+ 1, end: semicolon), in: scanner) {
            for unit in UTF8.encode(scalar)! {
                output[o] = unit
                o &+= 1
            }
            return (semicolon &+ 1, true)
        }
        for k in start...semicolon {
            output[o] = scanner.byte(k)
            o &+= 1
        }
        return (semicolon &+ 1, false)
    }

    /// The index of the `;` that ends the reference at `start`, or `end` if the name runs into
    /// any other byte first. Names have no length limit: `&#0000000065;` is a valid `A`.
    private static func referenceEnd(at start: Int, end: Int, in scanner: XMLScanner) -> Int {
        var i = start &+ 1
        while i < end {
            let byte = scanner.byte(i)
            if byte == UInt8(ascii: ";") { return i }
            let isNameByte = byte == UInt8(ascii: "#") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: ".") || (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
                || byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            guard isNameByte else { return end }
            i &+= 1
        }
        return end
    }

    /// The literal text of an unsupported reference, for its diagnostic.
    private static func referenceText(at start: Int, end: Int, in scanner: XMLScanner) -> String {
        let semicolon = referenceEnd(at: start, end: end, in: scanner)
        return scanner.string(ByteRange(start: start, end: semicolon < end ? semicolon &+ 1 : start &+ 1))
    }

    /// The scalar a reference name (between `&` and `;`) stands for. Returns nil for unknown
    /// entities and for references to characters that XML forbids.
    static func referencedScalar(_ name: ByteRange, in scanner: XMLScanner) -> Unicode.Scalar? {
        if scanner.bytes(name, equal: "amp") { return "&" }
        if scanner.bytes(name, equal: "lt") { return "<" }
        if scanner.bytes(name, equal: "gt") { return ">" }
        if scanner.bytes(name, equal: "quot") { return "\"" }
        if scanner.bytes(name, equal: "apos") { return "'" }
        guard name.count >= 2, scanner.byte(name.start) == UInt8(ascii: "#") else { return nil }

        var i = name.start &+ 1
        let isHex = scanner.byte(i) == UInt8(ascii: "x")
        if isHex { i &+= 1 }
        guard i < name.end else { return nil }
        var value: UInt32 = 0
        while i < name.end {
            let byte = scanner.byte(i)
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte &- 48)
            case UInt8(ascii: "a")...UInt8(ascii: "f") where isHex: digit = UInt32(byte &- 87)
            case UInt8(ascii: "A")...UInt8(ascii: "F") where isHex: digit = UInt32(byte &- 55)
            default: return nil
            }
            value = value &* (isHex ? 16 : 10) &+ digit
            guard value <= 0x10FFFF else { return nil }
            i &+= 1
        }
        // XML's Char production: no NUL, no C0 controls except tab/LF/CR, no surrogates, no FFFE/FFFF.
        switch value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return Unicode.Scalar(value)
        default: return nil
        }
    }
}
