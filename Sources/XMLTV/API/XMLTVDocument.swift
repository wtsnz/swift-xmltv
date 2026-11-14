import Foundation

/// A whole XMLTV guide, read into memory.
///
/// ```swift
/// let guide = try XMLTVDocument(contentsOf: url)          // .xml or .xml.gz
/// for programme in guide.programmes where programme.channelID == "BBC.One.uk" {
///     print(programme.start.date, programme.title ?? "")
/// }
/// ```
///
/// Large documents are parsed on every core. The result is identical to a serial parse:
/// channels and programmes appear in document order. To read a guide without holding all of
/// it in memory, use ``XMLTVReader``.
public struct XMLTVDocument: Sendable {
    /// The attributes of the `<tv>` root.
    public var info: TVInfo
    /// Channels in document order.
    public var channels: [Channel]
    /// Programmes in document order.
    public var programmes: [Programme]
    /// Diagnostics, truncation and encoding: everything about the parse except the data.
    public var report: ParseReport

    /// Reads and parses a file. Gzip compression is detected from the content, not the name.
    public init(contentsOf url: URL, options: ParseOptions = ParseOptions()) throws(XMLTVError) {
        self = try DocumentInput.withUTF8(contentsOf: url, options: options) { bytes, input throws(XMLTVError) in
            try XMLTVDocument(DocumentDriver.parse(bytes, input: input, options: options))
        }
    }

    /// Parses an XMLTV document held in memory, compressed or not.
    public init(data: Data, options: ParseOptions = ParseOptions()) throws(XMLTVError) {
        self = try DocumentInput.withUTF8(data: data, options: options) { bytes, input throws(XMLTVError) in
            try XMLTVDocument(DocumentDriver.parse(bytes, input: input, options: options))
        }
    }

    public init(info: TVInfo = TVInfo(), channels: [Channel] = [], programmes: [Programme] = [], report: ParseReport = ParseReport()) {
        self.info = info
        self.channels = channels
        self.programmes = programmes
        self.report = report
    }

    private init(_ output: DocumentDriver.Output) {
        self.init(info: output.info, channels: output.channels, programmes: output.programmes, report: output.report)
    }
}
