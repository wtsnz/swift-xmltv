#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What one call to ``XMLTVDecoder/next(boundary:)`` produced.
enum TopLevelItem {
    case channel(Channel)
    case programme(Programme)
    /// A top-level element was consumed without producing a record: the root start tag, an
    /// extension element, a filtered-out record, or one dropped for missing required data.
    case skipped
    /// The root element closed.
    case rootClosed
    /// The next top-level element starts at or after the boundary. It has not been consumed.
    case boundary
    /// The input is exhausted. In the epilog that means the document is complete; a streaming
    /// driver that expects more input keeps feeding it, so trailing content is still checked.
    case end
}

/// Decodes XMLTV records from a scanner, one top-level element per call.
///
/// The decoder is recursive descent: one method per XMLTV element, reading tokens straight from
/// the scanner, with no event or callback layer between them. Every driver uses this one
/// contract:
/// - The document parser and the parallel chunks call ``next(boundary:)`` until `.end` or
///   `.boundary`.
/// - The streaming reader calls it once per record. On `unexpectedEndOfInput` it rewinds to
///   where the call started, discards pending diagnostics and retries with more input. That works
///   because each call consumes at most one top-level construct, and every change of phase ends
///   the call that made it.
struct XMLTVDecoder {
    enum Phase {
        case prolog, body, epilog
        /// Content after the root was found and reported. Everything else is ignored.
        case finished
    }

    var scanner: XMLScanner
    var text = TextDecoder()
    var diagnostics: Diagnostics
    private(set) var phase: Phase
    private(set) var info: TVInfo?
    /// Offset of the `<` of the most recent top-level element.
    private(set) var elementStart = 0
    /// Child counts of the previous programme, used to size the next one's arrays.
    var expectedCounts = ExpectedCounts()

    let namedTimeZones: [String: Int32]
    private let channelIDs: Set<String>?
    private let timeWindow: Range<Int64>?

    /// The raw `channel` attribute of the previous programme and what it decoded to. Programmes
    /// arrive in runs per channel, so this skips decoding, interning and the selection test.
    private var lastChannelRaw: [UInt8] = []
    private var lastChannel = (id: "", isSelected: false)

    init(scanner: XMLScanner, phase: Phase, options: ParseOptions, recordsDiagnosticOffsets: Bool) {
        self.scanner = scanner
        self.phase = phase
        self.diagnostics = Diagnostics(
            policy: options.policy, sampleLimit: options.diagnosticLimit, recordsOffsets: recordsDiagnosticOffsets)
        self.namedTimeZones = options.namedTimeZones
        self.channelIDs = options.channelIDs
        self.timeWindow = options.timeWindow.map {
            Int64($0.lowerBound.timeIntervalSince1970.rounded(.down))..<Int64($0.upperBound.timeIntervalSince1970.rounded(.up))
        }
    }

    // MARK: Top level

    /// Decodes the next top-level construct. Leading whitespace, comments and the XML declaration
    /// are consumed on the way. Diagnostics are committed only when the call returns.
    ///
    /// - Parameter boundary: Stop, without consuming anything, before any top-level element
    ///   that starts at or after this offset. The parallel driver uses it to end chunks.
    mutating func next(boundary: Int = .max) throws(XMLTVError) -> TopLevelItem {
        let item = try decodeNext(boundary: boundary)
        diagnostics.commit()
        return item
    }

    private mutating func decodeNext(boundary: Int) throws(XMLTVError) -> TopLevelItem {
        if phase == .finished {
            scanner.position = scanner.end
            return .end
        }
        while true {
            let token = try scanner.next()
            switch phase {
            case .prolog:
                if try prolog(token) {
                    elementStart = scanner.tokenStart
                    return .skipped
                }

            case .body:
                switch token {
                case .startTag(let name, let isEmpty):
                    if scanner.tokenStart >= boundary {
                        scanner.position = scanner.tokenStart
                        return .boundary
                    }
                    elementStart = scanner.tokenStart
                    switch XMLTVElement(scanner.pointer(to: name)) {
                    case .programme:
                        guard let programme = try decodeProgramme(name, isEmpty: isEmpty) else { return .skipped }
                        return .programme(programme)
                    case .channel:
                        guard let channel = try decodeChannel(name, isEmpty: isEmpty) else { return .skipped }
                        return .channel(channel)
                    default:
                        try skipContent(of: name, isEmpty: isEmpty)
                        return .skipped
                    }
                case .endTag(let name):
                    guard scanner.bytes(name, equal: "tv") else {
                        throw XMLTVError(.mismatchedEndTag(expected: "tv", found: scanner.string(name)), byteOffset: scanner.tokenStart)
                    }
                    phase = .epilog
                    return .rootClosed
                case .text, .cdata:
                    continue
                case .endOfInput:
                    throw scanner.truncated()
                }

            case .epilog:
                switch token {
                case .endOfInput:
                    return .end
                case .text(let range, _) where isWhitespace(range):
                    continue
                default:
                    // Typically a second document appended to the first. Reported once; the rest
                    // of the input is ignored.
                    try diagnostics.report(.contentAfterRoot, at: scanner.tokenStart)
                    phase = .finished
                    scanner.position = scanner.end
                    return .end
                }

            case .finished:
                preconditionFailure("handled before the loop")
            }
        }
    }

    /// Handles a token before the root element. Returns true once `<tv>` has been read.
    private mutating func prolog(_ token: XMLToken) throws(XMLTVError) -> Bool {
        switch token {
        case .text(let range, _):
            guard isWhitespace(range) else { throw scanner.malformed("text before the root element") }
            return false
        case .startTag(let name, let isEmpty):
            guard XMLTVElement(scanner.pointer(to: name)) == .tv else {
                throw XMLTVError(.notXMLTV, byteOffset: scanner.tokenStart)
            }
            info = try decodeTVInfo()
            phase = isEmpty ? .epilog : .body
            return true
        case .endTag, .cdata:
            throw scanner.malformed("content before the root element")
        case .endOfInput:
            throw scanner.truncated()
        }
    }

    private mutating func decodeTVInfo() throws(XMLTVError) -> TVInfo {
        var info = TVInfo()
        for index in 0..<scanner.attributeCount {
            let attribute = scanner.attribute(at: index)
            let name = attribute.name
            if scanner.bytes(name, equal: "date") { info.date = try string(attribute) }
            else if scanner.bytes(name, equal: "source-info-url") { info.sourceInfoURL = try string(attribute) }
            else if scanner.bytes(name, equal: "source-info-name") { info.sourceInfoName = try string(attribute) }
            else if scanner.bytes(name, equal: "source-data-url") { info.sourceDataURL = try string(attribute) }
            else if scanner.bytes(name, equal: "generator-info-name") { info.generatorInfoName = try string(attribute) }
            else if scanner.bytes(name, equal: "generator-info-url") { info.generatorInfoURL = try string(attribute) }
        }
        return info
    }

    // MARK: Channel

    private mutating func decodeChannel(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Channel? {
        guard let idAttribute = scanner.attribute("id") else {
            try diagnostics.report(.missingAttribute(element: "channel", attribute: "id"), at: elementStart)
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        let id = try string(idAttribute)
        if let channelIDs, !channelIDs.contains(id) {
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }

        var channel = Channel(id: id)
        if !isEmpty {
            while true {
                switch try scanner.next() {
                case .startTag(let child, let childIsEmpty):
                    switch XMLTVElement(scanner.pointer(to: child)) {
                    case .displayName:
                        channel.displayNames.append(try localizedText(child, isEmpty: childIsEmpty))
                    case .icon:
                        if let icon = try icon(child, isEmpty: childIsEmpty) { channel.icons.append(icon) }
                    case .url:
                        channel.urls.append(try link(child, isEmpty: childIsEmpty))
                    default:
                        try skipContent(of: child, isEmpty: childIsEmpty)
                    }
                case .endTag(let closing):
                    try expectEndTag(closing, matching: name)
                    if channel.displayNames.isEmpty {
                        try diagnostics.report(.missingElement(element: "channel", child: "display-name"), at: elementStart)
                    }
                    return channel
                case .text, .cdata:
                    continue
                case .endOfInput:
                    throw scanner.truncated()
                }
            }
        }
        try diagnostics.report(.missingElement(element: "channel", child: "display-name"), at: elementStart)
        return channel
    }

    // MARK: Programme selection

    /// The programme's channel ID, and whether ``ParseOptions/channelIDs`` selects it.
    @inline(__always)
    mutating func channel(_ attribute: RawAttribute) throws(XMLTVError) -> (id: String, isSelected: Bool) {
        let raw = scanner.pointer(to: attribute.value)
        let isRepeat = lastChannelRaw.count == raw.count && lastChannelRaw.withUnsafeBufferPointer {
            raw.isEmpty || memcmp($0.baseAddress!, raw.baseAddress!, raw.count) == 0
        }
        if isRepeat { return lastChannel }

        let pendingBefore = diagnostics.pendingCount
        let id = try string(attribute)
        let decoded = (id: id, isSelected: channelIDs?.contains(id) ?? true)
        // A value that needed repair is not cached, so every occurrence reports its diagnostic.
        if diagnostics.pendingCount == pendingBefore {
            lastChannelRaw.removeAll(keepingCapacity: true)
            lastChannelRaw.append(contentsOf: raw)
            lastChannel = decoded
        }
        return decoded
    }

    /// Whether ``ParseOptions/timeWindow`` may select a programme. Programmes whose times cannot
    /// be compared exactly are kept.
    @inline(__always)
    func isInTimeWindow(start: XMLTVTimestamp, stop: XMLTVTimestamp?) -> Bool {
        guard let timeWindow else { return true }
        guard start.isTimeZoneKnown, stop?.isTimeZoneKnown ?? true else { return true }
        guard start.secondsSince1970 < timeWindow.upperBound else { return false }
        guard let stop else { return true }
        return stop.secondsSince1970 > timeWindow.lowerBound
    }

    // MARK: Shared element readers

    /// The trimmed text content of the element whose start tag was just read, through its end tag.
    ///
    /// The fast path is a single text token followed by the matching end tag. Text that is split
    /// by comments or CDATA, or that contains child elements, is gathered piece by piece. The
    /// text of nested children is ignored.
    @inline(__always)
    mutating func textContent(of name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> String {
        if isEmpty { return "" }
        let first = try scanner.next()
        switch first {
        case .endTag(let closing):
            try expectEndTag(closing, matching: name)
            return ""
        case .text(let range, let needsDecoding):
            let second = try scanner.next()
            if case .endTag(let closing) = second {
                try expectEndTag(closing, matching: name)
                return try text.text(range, needsDecoding: needsDecoding, in: scanner, diagnostics: &diagnostics)
            }
            text.beginPieces()
            try text.appendPiece(range, mode: .text, needsDecoding: needsDecoding, in: scanner, diagnostics: &diagnostics)
            return try remainingTextPieces(from: second, of: name, offset: range.start)
        default:
            text.beginPieces()
            return try remainingTextPieces(from: first, of: name, offset: scanner.tokenStart)
        }
    }

    private mutating func remainingTextPieces(
        from first: XMLToken, of name: ByteRange, offset: Int
    ) throws(XMLTVError) -> String {
        var token = first
        while true {
            switch token {
            case .text(let range, let needsDecoding):
                try text.appendPiece(range, mode: .text, needsDecoding: needsDecoding, in: scanner, diagnostics: &diagnostics)
            case .cdata(let range):
                try text.appendPiece(range, mode: .cdata, needsDecoding: false, in: scanner, diagnostics: &diagnostics)
            case .startTag(let child, let childIsEmpty):
                try skipContent(of: child, isEmpty: childIsEmpty)
            case .endTag(let closing):
                try expectEndTag(closing, matching: name)
                return try text.finishPieces(at: offset, diagnostics: &diagnostics)
            case .endOfInput:
                throw scanner.truncated()
            }
            token = try scanner.next()
        }
    }

    /// Text with its `lang` attribute, as in `<title lang="en">…</title>`.
    @inline(__always)
    mutating func localizedText(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> LocalizedText {
        let language = try scanner.attribute("lang").map { attribute throws(XMLTVError) in try string(attribute) }
        return LocalizedText(try textContent(of: name, isEmpty: isEmpty), language: language)
    }

    mutating func icon(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Icon? {
        let start = scanner.tokenStart
        var icon: Icon?
        if let source = scanner.attribute("src") {
            icon = Icon(
                source: try string(source),
                width: try scanner.attribute("width").flatMap { attribute throws(XMLTVError) in try integer(attribute, element: "icon") },
                height: try scanner.attribute("height").flatMap { attribute throws(XMLTVError) in try integer(attribute, element: "icon") })
        } else {
            try diagnostics.report(.missingAttribute(element: "icon", attribute: "src"), at: start)
        }
        try skipContent(of: name, isEmpty: isEmpty)
        return icon
    }

    mutating func link(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> URLReference {
        let system = try scanner.attribute("system").map { attribute throws(XMLTVError) in try string(attribute) }
        return URLReference(try textContent(of: name, isEmpty: isEmpty), system: system)
    }

    mutating func image(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.Image {
        var image = Programme.Image(url: "")
        for index in 0..<scanner.attributeCount {
            let attribute = scanner.attribute(at: index)
            if scanner.bytes(attribute.name, equal: "type") { image.type = try string(attribute) }
            else if scanner.bytes(attribute.name, equal: "size") { image.size = try string(attribute) }
            else if scanner.bytes(attribute.name, equal: "orient") { image.orientation = try string(attribute) }
            else if scanner.bytes(attribute.name, equal: "system") { image.system = try string(attribute) }
        }
        image.url = try textContent(of: name, isEmpty: isEmpty)
        return image
    }

    // MARK: Values

    /// The decoded string value of an attribute.
    @inline(__always)
    mutating func string(_ attribute: RawAttribute) throws(XMLTVError) -> String {
        try text.attribute(attribute, in: scanner, diagnostics: &diagnostics)
    }

    @inline(__always)
    mutating func timestamp(_ attribute: RawAttribute) throws(XMLTVError) -> XMLTVTimestamp? {
        let zones = namedTimeZones
        let outcome = try text.withAttributeBytes(attribute, in: scanner, diagnostics: &diagnostics) {
            TimestampParser.parse($0, namedZones: zones)
        }
        switch outcome {
        case .valid(let timestamp):
            return timestamp
        case .normalized(let timestamp):
            try diagnostics.report(.invalidTimestamp(scanner.string(attribute.value)), at: attribute.value.start)
            return timestamp
        case .unresolvedZone(let timestamp, let zone):
            try diagnostics.report(.unresolvedTimeZone(zone), at: attribute.value.start)
            return timestamp
        case .invalid:
            try diagnostics.report(.invalidTimestamp(scanner.string(attribute.value)), at: attribute.value.start)
            return nil
        }
    }

    mutating func integer(_ attribute: RawAttribute, element: String) throws(XMLTVError) -> Int? {
        let value = try text.withAttributeBytes(attribute, in: scanner, diagnostics: &diagnostics) { Self.integer($0) }
        if value == nil {
            try diagnostics.report(.invalidValue(element: element, value: scanner.string(attribute.value)), at: attribute.value.start)
        }
        return value
    }

    /// A non-negative decimal integer, surrounded by optional whitespace.
    static func integer(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var i = 0, end = bytes.count
        while i < end && bytes[i].isXMLWhitespace { i += 1 }
        while end > i && bytes[end - 1].isXMLWhitespace { end -= 1 }
        guard i < end, end - i <= 18 else { return nil }
        var value = 0
        while i < end {
            let digit = Int(bytes[i]) - 48
            guard (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
            i += 1
        }
        return value
    }

    // MARK: Structure

    @inline(__always)
    mutating func skipContent(of name: ByteRange, isEmpty: Bool) throws(XMLTVError) {
        if !isEmpty { try scanner.skipElement(named: name) }
    }

    @inline(__always)
    func expectEndTag(_ closing: ByteRange, matching name: ByteRange) throws(XMLTVError) {
        guard scanner.bytes(closing, equal: name) else { throw scanner.mismatch(expected: name, found: closing) }
    }

    func isWhitespace(_ range: ByteRange) -> Bool {
        var i = range.start
        while i < range.end {
            guard scanner.byte(i).isXMLWhitespace else { return false }
            i &+= 1
        }
        return true
    }
}
