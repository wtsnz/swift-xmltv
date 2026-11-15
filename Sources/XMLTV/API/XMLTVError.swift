import Foundation

/// An error thrown while reading XMLTV input.
///
/// Byte offsets refer to the UTF-8 form of the document, after decompression and transcoding.
/// For UTF-8 input that is the file itself, minus any byte-order mark.
///
/// `localizedDescription` gives a sentence that can be shown to a user. `description` adds the
/// location and the raw ``kind``, for logs.
public struct XMLTVError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// What went wrong.
    public var kind: Kind
    /// Offset into the UTF-8 document at which the problem was found.
    public var byteOffset: Int
    /// 1-based line of `byteOffset`, or 0 when the error is not tied to a position.
    public var line: Int
    /// 1-based column, in bytes, of `byteOffset`, or 0 when the error is not tied to a position.
    public var column: Int

    /// The kinds of problem. Input and markup problems are always errors. Content problems are
    /// diagnostics in lenient mode and errors in strict mode.
    ///
    /// New kinds may be added in a minor release, as new recovery rules are, so a `switch`
    /// needs `@unknown default`. To group or count kinds, use ``code``, which has no payload.
    @nonexhaustive
    public enum Kind: Sendable, Hashable {
        // Input

        /// A system call failed, with its `errno`. `operation` is the call, such as `open`.
        case io(operation: String, path: String, errno: Int32)
        /// The URL is not a file URL. To read from the network, download the file first, or use
        /// ``XMLTVItems``.
        case notAFileURL(String)
        /// The gzip data is corrupt or truncated. In lenient mode, what was decompressed before
        /// the damage is still parsed, and this is a diagnostic.
        case invalidCompressedData(String)
        /// The document declares an encoding the parser does not support.
        case unsupportedEncoding(String)
        /// The input is not valid in its encoding, such as an unpaired UTF-16 surrogate.
        case invalidEncoding

        // Markup. Always fatal, whatever the policy.

        /// The XML syntax is broken, for example an unquoted attribute value.
        case malformedMarkup(String)
        /// An end tag does not match the open element.
        case mismatchedEndTag(expected: String, found: String)
        /// The input ended inside the document. In lenient mode, a truncated document keeps its
        /// complete records and this is a diagnostic.
        case unexpectedEndOfInput
        /// The input is not an XMLTV document: it is empty, it is not XML (such as a JSON error
        /// body), or its root element is not `<tv>` (such as an HTML error page).
        case notXMLTV
        /// A streaming parse met a single construct larger than
        /// ``XMLTVOptions/maximumRecordSize``, which is given, in bytes: a record, a skipped
        /// element or a comment. Always fatal, whatever the policy.
        case recordTooLarge(maximumSize: Int)

        // Content. Diagnostics in lenient mode.

        /// A required attribute is absent, such as a programme's `start`.
        case missingAttribute(element: String, attribute: String)
        /// A required child is absent, such as a programme's `<title>`.
        case missingElement(element: String, child: String)
        /// A value that could not be interpreted: the text of an element, such as a non-numeric
        /// `<length>`, or, when `attribute` is not nil, an attribute of it, such as `clumpidx`.
        case invalidValue(element: String, attribute: String?, value: String)
        /// A timestamp that could not be parsed, or one that needed normalising, such as minute 60.
        case invalidTimestamp(String)
        /// A zone name missing from ``XMLTVOptions/namedTimeZones``.
        case unresolvedTimeZone(String)
        /// An entity reference other than the five XML defines, or a reference to a forbidden
        /// character. It is kept literally.
        case unsupportedEntity(String)
        /// Text that is not valid UTF-8. It is repaired with U+FFFD.
        case invalidUTF8
        /// A character XML does not allow, such as NUL or U+FFFF, given as its scalar value.
        case invalidCharacter(UInt32)
        /// Content after the root element closed, usually a second document appended to the
        /// first. It is ignored.
        case contentAfterRoot

        /// The kind without its details, for grouping and counting.
        public var code: Code {
            switch self {
            case .io: .io
            case .notAFileURL: .notAFileURL
            case .invalidCompressedData: .invalidCompressedData
            case .unsupportedEncoding: .unsupportedEncoding
            case .invalidEncoding: .invalidEncoding
            case .malformedMarkup: .malformedMarkup
            case .mismatchedEndTag: .mismatchedEndTag
            case .unexpectedEndOfInput: .unexpectedEndOfInput
            case .notXMLTV: .notXMLTV
            case .recordTooLarge: .recordTooLarge
            case .missingAttribute: .missingAttribute
            case .missingElement: .missingElement
            case .invalidValue: .invalidValue
            case .invalidTimestamp: .invalidTimestamp
            case .unresolvedTimeZone: .unresolvedTimeZone
            case .unsupportedEntity: .unsupportedEntity
            case .invalidUTF8: .invalidUTF8
            case .invalidCharacter: .invalidCharacter
            case .contentAfterRoot: .contentAfterRoot
            }
        }

        /// A sentence describing the problem, for people.
        public var message: String {
            switch self {
            case .io(let operation, let path, let errno):
                "The file “\(path)” could not be read (\(operation): \(String(cString: strerror(errno))))."
            case .notAFileURL(let url):
                "“\(url)” is not a file. Download it first."
            case .invalidCompressedData(let detail):
                "The compressed data is damaged (\(detail))."
            case .unsupportedEncoding(let name):
                "The guide uses the text encoding “\(name)”, which is not supported."
            case .invalidEncoding:
                "Some text is not valid in the guide's encoding."
            case .malformedMarkup(let detail):
                "The guide is not well-formed XML: \(detail)."
            case .mismatchedEndTag(let expected, let found):
                "The guide is not well-formed XML: found </\(found)> where </\(expected)> was expected."
            case .unexpectedEndOfInput:
                "The guide ends early, as if the download was cut off."
            case .notXMLTV:
                "This is not an XMLTV guide."
            case .recordTooLarge(let maximumSize):
                "The guide has a record larger than the \(maximumSize / (1 << 20)) MiB that a streaming read allows."
            case .missingAttribute(let element, let attribute):
                "\(Self.article(element)) <\(element)> has no “\(attribute)” attribute."
            case .missingElement(let element, let child):
                "\(Self.article(element)) <\(element)> has no <\(child)>."
            case .invalidValue(let element, let attribute?, let value):
                "\(Self.article(element)) <\(element)> has a “\(attribute)” attribute that could not be read: “\(value)”."
            case .invalidValue(let element, nil, ""):
                "\(Self.article(element)) <\(element)> is empty."
            case .invalidValue(let element, nil, let value):
                "\(Self.article(element)) <\(element)> has a value that could not be read: “\(value)”."
            case .invalidTimestamp(let text):
                "The time “\(text)” is not valid."
            case .unresolvedTimeZone(let name):
                "The time zone “\(name)” is not known."
            case .unsupportedEntity(let reference):
                "The entity reference “\(reference)” is not supported."
            case .invalidUTF8:
                "Some text is not valid UTF-8."
            case .invalidCharacter(let scalar):
                "The text contains a character XML does not allow (U+\(String(scalar, radix: 16, uppercase: true)))."
            case .contentAfterRoot:
                "There is content after the end of the guide."
            }
        }

        /// "An" before an element name that starts with a vowel, such as `icon`, else "A".
        private static func article(_ element: String) -> String {
            element.first.map { "aeiou".contains($0) } == true ? "An" : "A"
        }
    }

    /// The kind of a problem, without its details. Use it to group, count or look up
    /// diagnostics, as in ``XMLTVReport/diagnosticCountsByCode``. The raw value is the name of the
    /// ``Kind`` case, which is stable and suitable for logs.
    @nonexhaustive
    public enum Code: String, Sendable, Hashable, CaseIterable, Codable {
        case io, notAFileURL, invalidCompressedData, unsupportedEncoding, invalidEncoding
        case malformedMarkup, mismatchedEndTag, unexpectedEndOfInput, notXMLTV, recordTooLarge
        case missingAttribute, missingElement, invalidValue, invalidTimestamp, unresolvedTimeZone
        case unsupportedEntity, invalidUTF8, invalidCharacter, contentAfterRoot
    }

    public init(_ kind: Kind, byteOffset: Int = 0, line: Int = 0, column: Int = 0) {
        self.kind = kind
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
    }

    /// The kind without its details: shorthand for `kind.code`.
    public var code: Code { kind.code }

    /// The problem, as a sentence for people. For example: “The guide is not well-formed XML:
    /// found </desc> where </title> was expected. (line 12, column 40)”. The location is left
    /// out when there is none, and for input that is not a guide at all, where it would add
    /// nothing.
    public var errorDescription: String? {
        line > 0 && kind != .notXMLTV ? "\(kind.message) (line \(line), column \(column))" : kind.message
    }

    public var description: String {
        let location = line > 0 ? "line \(line), column \(column)" : "byte \(byteOffset)"
        return "XMLTV error at \(location): \(kind)"
    }
}

/// A recoverable problem found in `.lenient` mode. In `.strict` mode the same problem is thrown
/// as an ``XMLTVError``.
public struct XMLTVDiagnostic: Sendable, Hashable, CustomStringConvertible {
    /// What was wrong.
    public var kind: XMLTVError.Kind
    /// What the parser did about it.
    public var recovery: Recovery
    /// Offset into the UTF-8 document at which the problem was found.
    public var byteOffset: Int
    /// 1-based line of `byteOffset`.
    public var line: Int

    /// What the parser did about a problem. ``XMLTVReport`` counts the records each one cost.
    @nonexhaustive
    public enum Recovery: String, Sendable, Hashable, CaseIterable, Codable {
        /// The value was corrected and kept: a timestamp with minute 60 was normalised, or
        /// invalid text was repaired with U+FFFD.
        case repaired
        /// The value was kept as written, or the record was kept without the missing part, such
        /// as a programme with no title.
        case keptAsWritten
        /// A default was used in place of the value, such as UTC for an unknown zone name.
        case assumedDefault
        /// The value, or the child element holding it, was discarded. The record is kept.
        case valueDropped
        /// The whole programme was discarded, for example because its start time is invalid.
        case programmeDropped
        /// The whole channel was discarded, because it has no `id`.
        case channelDropped
        /// The rest of the input was ignored: content after the root, damaged compressed data,
        /// or a document cut off before it ended.
        case restOfInputIgnored
    }

    public init(kind: XMLTVError.Kind, recovery: Recovery, byteOffset: Int = 0, line: Int = 0) {
        self.kind = kind
        self.recovery = recovery
        self.byteOffset = byteOffset
        self.line = line
    }

    /// The kind without its details: shorthand for `kind.code`.
    public var code: XMLTVError.Code { kind.code }

    /// The problem and what was done about it, as a sentence for people. For example: “Line 12:
    /// The time “2024-01-01T12:00” is not valid. The programme was skipped.” The line is left out
    /// when it is 0.
    public var message: String {
        let outcome = switch recovery {
        case .repaired: "It was repaired."
        case .keptAsWritten: "It was kept as written."
        case .assumedDefault: "A default was used."
        case .valueDropped: "The value was skipped."
        case .programmeDropped: "The programme was skipped."
        case .channelDropped: "The channel was skipped."
        case .restOfInputIgnored: "The rest of the input was ignored."
        }
        return line > 0 ? "Line \(line): \(kind.message) \(outcome)" : "\(kind.message) \(outcome)"
    }

    public var description: String {
        line > 0 ? "line \(line): \(kind) (\(recovery.rawValue))" : "\(kind) (\(recovery.rawValue))"
    }
}
