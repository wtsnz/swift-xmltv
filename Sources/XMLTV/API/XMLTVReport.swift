/// What happened during a parse, apart from the data itself.
///
/// The counts cover the whole document. ``diagnostics`` holds only the first
/// ``XMLTVOptions/diagnosticLimit`` of them, so use the counts for a summary such as "12
/// programmes were skipped", and the list for detail.
public struct XMLTVReport: Sendable, Hashable {
    /// The encoding the input was read as.
    public var encoding: XMLTVEncoding = .utf8
    /// The UTF-8 bytes decoded so far: after decompression and transcoding, so for a gzip file
    /// this exceeds the file size. Complete once the parse has finished.
    public var decodedByteCount = 0
    /// The input bytes consumed so far, before decompression and transcoding. For progress,
    /// divide this by the size of the file or download.
    public var inputByteCount = 0
    /// True when the input ended inside the document, as with a cut-off download. Every
    /// complete record before that point was kept. Only `.lenient` parses can be truncated;
    /// `.strict` throws instead.
    public var isTruncated = false
    /// The first ``XMLTVOptions/diagnosticLimit`` diagnostics, in document order.
    public var diagnostics: [XMLTVDiagnostic] = []
    /// The number of diagnostics, including those not kept in ``diagnostics``.
    public var diagnosticCount = 0
    /// The number of diagnostics of each kind, including those not kept in ``diagnostics``.
    /// Kinds that did not occur are absent.
    public var diagnosticCountsByCode: [XMLTVError.Code: Int] = [:]
    /// Programmes discarded because of a problem, such as an invalid start time. Programmes on
    /// channels that ``XMLTVOptions/channelIDs`` excludes are skipped before they are checked,
    /// so they are not counted, and none of their problems is reported. (In `.strict` mode, the
    /// `channel` attribute itself must still be valid text, as it is read to make the choice.)
    /// With a channel filter, that includes programmes with no channel. Programmes lost after
    /// the end of a truncated document are not counted either. A programme with an invalid
    /// start is counted even with a ``XMLTVOptions/timeWindow``, because the window cannot be
    /// applied to it.
    public var droppedProgrammeCount = 0
    /// Channels discarded because of a problem: a channel with no `id`.
    public var droppedChannelCount = 0

    public init() {}

    /// Counts one diagnostic.
    mutating func count(_ code: XMLTVError.Code, _ recovery: XMLTVDiagnostic.Recovery) {
        diagnosticCount += 1
        diagnosticCountsByCode[code, default: 0] += 1
        if recovery == .programmeDropped { droppedProgrammeCount += 1 }
        if recovery == .channelDropped { droppedChannelCount += 1 }
    }

    /// Adds one diagnostic, keeping it if there is room.
    mutating func add(_ diagnostic: XMLTVDiagnostic, limit: Int) {
        count(diagnostic.kind.code, diagnostic.recovery)
        if diagnostics.count < limit { diagnostics.append(diagnostic) }
    }
}
