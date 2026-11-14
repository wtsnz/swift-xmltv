#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A half-open range of byte offsets into the scanner's buffer.
struct ByteRange: Equatable {
    var start: Int
    var end: Int

    @inline(__always) var count: Int { end &- start }
    @inline(__always) var isEmpty: Bool { start == end }
}

/// One `name="value"` pair of the most recent start tag, as offsets into the buffer.
struct RawAttribute {
    var name: ByteRange
    var value: ByteRange
    /// The value contains `&`, or a control byte (tab, CR, LF) that XML normalises to a space.
    var needsDecoding: Bool
}

/// A token is a set of offsets into the scanner's buffer. Tokens own no memory.
enum XMLToken {
    case startTag(name: ByteRange, isEmpty: Bool)
    case endTag(name: ByteRange)
    case text(ByteRange, needsDecoding: Bool)
    case cdata(ByteRange)
    case endOfInput
}

/// Reusable working memory for a scanner: the current start tag's attributes, and the stack of
/// open element names inside a skipped subtree.
///
/// It is a class only so that the allocations are freed with the last scanner that uses them.
/// Its properties are `let`s, so reads need no exclusivity checks. When a tag has more
/// attributes than fit, the scanner replaces the storage with a larger one.
final class ScannerStorage {
    let attributes: UnsafeMutablePointer<RawAttribute>
    let attributeCapacity: Int
    let openElements: UnsafeMutablePointer<ByteRange>
    static let maximumSkippedDepth = 1024

    init(attributeCapacity: Int = 32) {
        self.attributeCapacity = attributeCapacity
        attributes = .allocate(capacity: attributeCapacity)
        openElements = .allocate(capacity: ScannerStorage.maximumSkippedDepth)
    }

    deinit {
        attributes.deallocate()
        openElements.deallocate()
    }
}

/// A pull tokenizer for the subset of XML 1.0 that XMLTV uses.
///
/// - Elements, attributes (either quote style), text, CDATA, comments, processing
///   instructions and a DOCTYPE (with an internal subset) are recognised. Comments, processing
///   instructions and the DOCTYPE are consumed silently.
/// - There are no namespaces and no DTD-declared entities. Text is reported as raw ranges, and
///   ``TextDecoder`` turns them into strings.
/// - Attributes are parsed eagerly, in the same pass that finds the closing `>`. They stay valid
///   until the next call to ``next()``.
///
/// The scanner reads through a raw pointer. It is an internal type, and every driver creates it
/// inside the scope that keeps the buffer alive.
struct XMLScanner {
    private(set) var base: UnsafePointer<UInt8>
    private(set) var end: Int
    /// Offset of the next byte to read.
    var position: Int
    /// Offset of the `<` (or first text byte) of the token most recently returned.
    private(set) var tokenStart: Int

    private var storage: ScannerStorage
    private(set) var attributeCount = 0

    init(_ buffer: UnsafeBufferPointer<UInt8>, position: Int = 0, storage: ScannerStorage = ScannerStorage()) {
        // An empty buffer has no base address. Any non-null pointer will do: with `end == 0`
        // nothing is ever read through it.
        self.base = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        self.end = buffer.count
        self.position = position
        self.tokenStart = position
        self.storage = storage
    }

    /// Points the scanner at a new buffer, keeping its storage. Used by the streaming driver,
    /// whose buffer moves when it grows.
    mutating func rebind(to buffer: UnsafeBufferPointer<UInt8>, position: Int) {
        self = XMLScanner(buffer, position: position, storage: storage)
    }

    // MARK: Byte access

    @inline(__always) func byte(_ index: Int) -> UInt8 { base[index] }

    @inline(__always) func pointer(to range: ByteRange) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: base + range.start, count: range.count)
    }

    @inline(__always) func bytes(_ range: ByteRange, equal literal: StaticString) -> Bool {
        range.count == literal.utf8CodeUnitCount && memcmp(base + range.start, literal.utf8Start, range.count) == 0
    }

    @inline(__always) func bytes(_ a: ByteRange, equal b: ByteRange) -> Bool {
        a.count == b.count && memcmp(base + a.start, base + b.start, a.count) == 0
    }

    func string(_ range: ByteRange) -> String {
        String(decoding: pointer(to: range), as: UTF8.self)
    }

    // MARK: Attributes

    @inline(__always) func attribute(at index: Int) -> RawAttribute {
        storage.attributes[index]
    }

    /// The first attribute of the current start tag with the given name.
    @inline(__always) func attribute(_ name: StaticString) -> RawAttribute? {
        var i = 0
        while i < attributeCount {
            let attribute = storage.attributes[i]
            if bytes(attribute.name, equal: name) { return attribute }
            i &+= 1
        }
        return nil
    }

    // MARK: Tokens

    @inline(__always)
    mutating func next() throws(XMLTVError) -> XMLToken {
        while true {
            tokenStart = position
            guard position < end else { return .endOfInput }

            if base[position] != UInt8(ascii: "<") {
                let (stop, needsDecoding) = ByteSearch.stop(
                    at: UInt8(ascii: "<"), in: base, from: position, end: end, flagControls: false)
                position = stop
                return .text(ByteRange(start: tokenStart, end: stop), needsDecoding: needsDecoding)
            }

            guard position &+ 1 < end else { throw truncated() }
            switch base[position &+ 1] {
            case UInt8(ascii: "/"):
                return .endTag(name: try scanEndTag())
            case UInt8(ascii: "!"):
                if let cdata = try scanMarkupDeclaration() { return .cdata(cdata) }
            case UInt8(ascii: "?"):
                try skip(past: "?>", from: position &+ 2)
            default:
                return try scanStartTag(recordingAttributes: true)
            }
        }
    }

    /// Consumes the content and end tag of the element whose start tag was just returned.
    ///
    /// This is the fast path for extension elements and filtered-out programmes. It jumps
    /// between `<` bytes with SIMD, creates no strings and does not decode text or attribute
    /// values. It still checks the markup: start tags are parsed with the usual syntax rules, and
    /// every end tag must match its start tag. Comments, CDATA and processing instructions are
    /// handled lexically, so a `</programme>` inside a comment does not end the element.
    mutating func skipElement(named name: ByteRange) throws(XMLTVError) {
        var depth = 0                       // open elements inside the skipped one
        let openElements = storage.openElements
        while true {
            position = ByteSearch.first(UInt8(ascii: "<"), in: base, from: position, end: end)
            tokenStart = position
            guard position &+ 1 < end else { throw truncated() }
            switch base[position &+ 1] {
            case UInt8(ascii: "/"):
                let closing = try scanEndTag()
                if depth == 0 {
                    guard bytes(closing, equal: name) else { throw mismatch(expected: name, found: closing) }
                    return
                }
                depth &-= 1
                guard bytes(closing, equal: openElements[depth]) else {
                    throw mismatch(expected: openElements[depth], found: closing)
                }
            case UInt8(ascii: "!"):
                _ = try scanMarkupDeclaration()
            case UInt8(ascii: "?"):
                try skip(past: "?>", from: position &+ 2)
            default:
                guard case .startTag(let child, let isEmpty) = try scanStartTag(recordingAttributes: false) else {
                    preconditionFailure("scanStartTag returns start tags")
                }
                if !isEmpty {
                    guard depth < ScannerStorage.maximumSkippedDepth else { throw malformed("elements nested too deeply") }
                    openElements[depth] = child
                    depth &+= 1
                }
            }
        }
    }

    // MARK: Tags

    /// Consumes a start tag at `position`. With `recordingAttributes`, the attributes are stored
    /// for ``attribute(at:)``; either way their syntax is checked.
    @inline(__always)
    private mutating func scanStartTag(recordingAttributes: Bool) throws(XMLTVError) -> XMLToken {
        let nameStart = position &+ 1
        var i = nameStart
        while i < end {
            let b = base[i]
            if b.isXMLWhitespace || b == UInt8(ascii: ">") || b == UInt8(ascii: "/") { break }
            i &+= 1
        }
        let name = ByteRange(start: nameStart, end: i)
        guard !name.isEmpty else { throw malformed("empty element name") }

        if recordingAttributes { attributeCount = 0 }
        while true {
            while i < end && base[i].isXMLWhitespace { i &+= 1 }
            guard i < end else { throw truncated() }
            switch base[i] {
            case UInt8(ascii: ">"):
                position = i &+ 1
                return .startTag(name: name, isEmpty: false)
            case UInt8(ascii: "/"):
                guard i &+ 1 < end else { throw truncated() }
                guard base[i &+ 1] == UInt8(ascii: ">") else { throw malformed("expected '>' after '/'") }
                position = i &+ 2
                return .startTag(name: name, isEmpty: true)
            default:
                i = try scanAttribute(from: i, recording: recordingAttributes)
            }
        }
    }

    /// Parses one `name = "value"` pair starting at `i` and returns the index just past it.
    @inline(__always)
    private mutating func scanAttribute(from start: Int, recording: Bool) throws(XMLTVError) -> Int {
        var i = start
        while i < end {
            let b = base[i]
            if b == UInt8(ascii: "=") || b.isXMLWhitespace || b == UInt8(ascii: ">") || b == UInt8(ascii: "/") { break }
            i &+= 1
        }
        let name = ByteRange(start: start, end: i)
        while i < end && base[i].isXMLWhitespace { i &+= 1 }
        guard i < end else { throw truncated() }
        guard base[i] == UInt8(ascii: "=") else { throw malformed("attribute without a value") }
        i &+= 1
        while i < end && base[i].isXMLWhitespace { i &+= 1 }
        guard i < end else { throw truncated() }
        let quote = base[i]
        guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
            throw malformed("attribute value is not quoted")
        }
        let (close, needsDecoding) = ByteSearch.stop(at: quote, in: base, from: i &+ 1, end: end, flagControls: true)
        guard close < end else { throw truncated() }
        let value = ByteRange(start: i &+ 1, end: close)
        // The search flags `<` along with `&` and controls, so this check is rare.
        if needsDecoding && ByteSearch.first(UInt8(ascii: "<"), in: base, from: value.start, end: value.end) < value.end {
            throw malformed("'<' in an attribute value")
        }
        if recording {
            if attributeCount == storage.attributeCapacity { growAttributeStorage() }
            storage.attributes[attributeCount] = RawAttribute(name: name, value: value, needsDecoding: needsDecoding)
            attributeCount &+= 1
        }

        let after = close &+ 1
        guard after < end else { throw truncated() }
        let next = base[after]
        guard next.isXMLWhitespace || next == UInt8(ascii: ">") || next == UInt8(ascii: "/") else {
            throw malformed("attributes must be separated by whitespace")
        }
        return after
    }

    /// Consumes `</name>` at `position` and returns the name.
    @inline(__always)
    private mutating func scanEndTag() throws(XMLTVError) -> ByteRange {
        let nameStart = position &+ 2
        var i = nameStart
        while i < end {
            let b = base[i]
            if b == UInt8(ascii: ">") || b.isXMLWhitespace { break }
            i &+= 1
        }
        let name = ByteRange(start: nameStart, end: i)
        while i < end && base[i].isXMLWhitespace { i &+= 1 }
        guard i < end else { throw truncated() }
        guard base[i] == UInt8(ascii: ">"), !name.isEmpty else { throw malformed("malformed end tag") }
        position = i &+ 1
        return name
    }

    private mutating func growAttributeStorage() {
        let larger = ScannerStorage(attributeCapacity: storage.attributeCapacity * 2)
        larger.attributes.update(from: storage.attributes, count: attributeCount)
        storage = larger
    }

    // MARK: Declarations

    /// Consumes `<!--…-->`, `<![CDATA[…]]>` or `<!DOCTYPE…>` at `position`. Returns the content
    /// range for CDATA, and nil otherwise.
    private mutating func scanMarkupDeclaration() throws(XMLTVError) -> ByteRange? {
        if try hasPrefix("<!--") {
            try skip(past: "-->", from: position &+ 4)
            return nil
        }
        if try hasPrefix("<![CDATA[") {
            let contentStart = position &+ 9
            let close = ByteSearch.first("]]>", in: base, from: contentStart, end: end)
            guard close < end else { throw truncated() }
            position = close &+ 3
            return ByteRange(start: contentStart, end: close)
        }
        if try hasPrefix("<!DOCTYPE") {
            try skipDoctype()
            return nil
        }
        throw malformed("unknown markup declaration")
    }

    /// Skips a DOCTYPE, including quoted identifiers and a bracketed internal subset. Entity
    /// declarations in the subset are not expanded.
    private mutating func skipDoctype() throws(XMLTVError) {
        var i = position &+ 9
        var subsetDepth = 0
        while i < end {
            switch base[i] {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                let close = ByteSearch.first(base[i], in: base, from: i &+ 1, end: end)
                guard close < end else { throw truncated() }
                i = close
            case UInt8(ascii: "<") where subsetDepth > 0 && i &+ 3 < end && base[i &+ 1] == UInt8(ascii: "!")
                && base[i &+ 2] == UInt8(ascii: "-") && base[i &+ 3] == UInt8(ascii: "-"):
                // A comment in the internal subset may contain quotes and brackets.
                let close = ByteSearch.first("-->", in: base, from: i &+ 4, end: end)
                guard close < end else { throw truncated() }
                i = close &+ 2
            case UInt8(ascii: "["): subsetDepth &+= 1
            case UInt8(ascii: "]"): subsetDepth &-= 1
            case UInt8(ascii: ">") where subsetDepth <= 0:
                position = i &+ 1
                return
            default: break
            }
            i &+= 1
        }
        throw truncated()
    }

    /// Whether the input at `position` starts with `literal`. Throws `unexpectedEndOfInput` if
    /// the input ends partway through a match, so a streaming driver waits for more.
    private func hasPrefix(_ literal: StaticString) throws(XMLTVError) -> Bool {
        let available = min(literal.utf8CodeUnitCount, end &- position)
        guard memcmp(base + position, literal.utf8Start, available) == 0 else { return false }
        if available < literal.utf8CodeUnitCount { throw truncated() }
        return true
    }

    private mutating func skip(past terminator: StaticString, from start: Int) throws(XMLTVError) {
        let found = ByteSearch.first(terminator, in: base, from: start, end: end)
        guard found < end else { throw truncated() }
        position = found &+ terminator.utf8CodeUnitCount
    }

    // MARK: Errors

    func truncated() -> XMLTVError { XMLTVError(.unexpectedEndOfInput, byteOffset: end) }

    func malformed(_ reason: String) -> XMLTVError {
        XMLTVError(.malformedMarkup(reason), byteOffset: tokenStart)
    }

    func mismatch(expected: ByteRange, found: ByteRange) -> XMLTVError {
        XMLTVError(.mismatchedEndTag(expected: string(expected), found: string(found)), byteOffset: tokenStart)
    }
}

extension UInt8 {
    /// XML's `S` production: space, tab, line feed, carriage return.
    @inline(__always) var isXMLWhitespace: Bool {
        self == 0x20 || self == 0x0A || self == 0x09 || self == 0x0D
    }
}
