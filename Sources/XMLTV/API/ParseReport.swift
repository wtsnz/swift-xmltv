/// What happened during a parse, apart from the data itself.
public struct ParseReport: Sendable, Hashable {
    /// The encoding the input was read as.
    public var encoding: XMLTVEncoding = .utf8
    /// The size of the document in UTF-8 bytes.
    public var byteCount = 0
    /// True when the input ended inside the document, as with a cut-off download. Every
    /// complete record before that point was kept. Only `.lenient` parses can be truncated;
    /// `.strict` throws instead.
    public var isTruncated = false
    /// The first ``ParseOptions/diagnosticLimit`` diagnostics, in document order.
    public var diagnostics: [XMLTVDiagnostic] = []
    /// The number of diagnostics, including those not kept in ``diagnostics``.
    public var diagnosticCount = 0

    public init() {}
}
