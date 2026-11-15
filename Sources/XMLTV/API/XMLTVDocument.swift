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
///
/// The file and `Data` initializers are synchronous and use every core until they return, so
/// call them off the main actor; see <doc:ChoosingAnEntryPoint#Concurrency>. For channel
/// schedules and what is on now, build an ``XMLTVSchedule`` from the document.
///
/// Documents are equal when their info, channels and programmes are, so comparing the old and
/// new documents tells whether a refresh changed the guide. The ``report`` is left out: it
/// describes how the bytes arrived, so the same guide gzipped or not, or with different byte
/// counts, is still the same guide. Comparing and hashing visit every record: hashing the 1.93 GB
/// feed takes about 2 seconds. For a large guide, do either off the main actor.
public struct XMLTVDocument: Sendable, Hashable {
    /// The attributes of the `<tv>` root.
    public var info: TVInfo
    /// Channels in document order.
    public var channels: [Channel]
    /// Programmes in document order.
    public var programmes: [Programme]
    /// Diagnostics, truncation and encoding: everything about the parse except the data.
    public var report: XMLTVReport

    /// Reads and parses a file. Gzip compression is detected from the content, not the name.
    ///
    /// The URL must be a file URL. To read a guide from the network, download it to a file
    /// first, which is the fastest way, or use ``init(chunks:options:)``.
    public init(contentsOf url: URL, options: XMLTVOptions = XMLTVOptions()) throws(XMLTVError) {
        self = try DocumentInput.withUTF8(contentsOf: url, options: options) { bytes, input throws(XMLTVError) in
            try XMLTVDocument(DocumentDriver.parse(bytes, input: input, options: options))
        }
    }

    /// Parses an XMLTV document held in memory, compressed or not.
    public init(data: Data, options: XMLTVOptions = XMLTVOptions()) throws(XMLTVError) {
        self = try DocumentInput.withUTF8(data: data, options: options) { bytes, input throws(XMLTVError) in
            try XMLTVDocument(DocumentDriver.parse(bytes, input: input, options: options))
        }
    }

    /// Collects a document arriving as a sequence of byte chunks, such as a download, as the
    /// chunks arrive. The parse is serial; see ``XMLTVItems`` to handle records one at a time.
    ///
    /// Errors from the source are rethrown unchanged. Parse errors are ``XMLTVError``. A cancelled
    /// task gets `CancellationError`, not the part of the guide read so far.
    public init<Chunks: AsyncSequence>(
        chunks: Chunks, options: XMLTVOptions = XMLTVOptions()
    ) async throws where Chunks.Element: ContiguousBytes {
        var iterator = XMLTVItems(chunks: chunks, options: options).makeAsyncIterator()
        var channels: [Channel] = [], programmes: [Programme] = []
        while let item = try await iterator.next() {
            switch item {
            case .channel(let channel): channels.append(channel)
            case .programme(let programme): programmes.append(programme)
            }
        }
        self.init(info: iterator.info ?? TVInfo(), channels: channels, programmes: programmes, report: iterator.report)
    }

    public init(info: TVInfo = TVInfo(), channels: [Channel] = [], programmes: [Programme] = [], report: XMLTVReport = XMLTVReport()) {
        self.info = info
        self.channels = channels
        self.programmes = programmes
        self.report = report
    }

    /// The first channel with this ID, or nil if none is declared. Feeds may declare an ID more
    /// than once; ``channels`` keeps every record.
    ///
    /// This searches ``channels`` from the start. For many lookups, as in a loop over channels,
    /// use ``XMLTVSchedule/channel(_:)``, which looks them up in a dictionary.
    public func channel(id: String) -> Channel? {
        channels.first { $0.id == id }
    }

    public static func == (lhs: XMLTVDocument, rhs: XMLTVDocument) -> Bool {
        lhs.info == rhs.info && lhs.channels == rhs.channels && lhs.programmes == rhs.programmes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(info)
        hasher.combine(channels)
        hasher.combine(programmes)
    }

    private init(_ output: DocumentDriver.Output) {
        self.init(info: output.info, channels: output.channels, programmes: output.programmes, report: output.report)
    }
}
