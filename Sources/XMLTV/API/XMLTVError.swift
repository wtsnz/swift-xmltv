/// An error thrown while reading XMLTV input.
///
/// Byte offsets refer to the UTF-8 form of the document, after decompression and transcoding.
/// For UTF-8 input that is the file itself, minus any byte-order mark.
public struct XMLTVError: Error, Sendable, Hashable, CustomStringConvertible {
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
    public enum Kind: Sendable, Hashable {
        // Input

        /// A system call failed, with its `errno`.
        case io(operation: String, errno: Int32)
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
        /// The input is empty, or its root element is not `<tv>`.
        case notXMLTV

        // Content. Diagnostics in lenient mode.

        /// A required attribute is absent, such as a programme's `start`.
        case missingAttribute(element: String, attribute: String)
        /// A required child is absent, such as a programme's `<title>`.
        case missingElement(element: String, child: String)
        /// A value that could not be interpreted, such as a non-numeric `<length>`.
        case invalidValue(element: String, value: String)
        /// A timestamp that could not be parsed, or one that needed normalising, such as minute 60.
        case invalidTimestamp(String)
        /// A zone name missing from ``ParseOptions/namedTimeZones``.
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
    }

    public init(_ kind: Kind, byteOffset: Int = 0, line: Int = 0, column: Int = 0) {
        self.kind = kind
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
    }

    public var description: String {
        let location = line > 0 ? "line \(line), column \(column)" : "byte \(byteOffset)"
        return "XMLTV error at \(location): \(kind)"
    }
}

/// A recoverable problem found in `.lenient` mode. In `.strict` mode the same problem is thrown
/// as an ``XMLTVError``.
public struct XMLTVDiagnostic: Sendable, Hashable, CustomStringConvertible {
    /// What was recovered from.
    public var kind: XMLTVError.Kind
    /// Offset into the UTF-8 document at which the problem was found.
    public var byteOffset: Int
    /// 1-based line of `byteOffset`.
    public var line: Int

    public var description: String { "line \(line): \(kind)" }
}
