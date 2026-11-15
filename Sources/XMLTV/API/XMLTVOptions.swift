import Foundation

/// Options for ``XMLTVDocument``, ``XMLTVReader`` and ``XMLTVItems``.
///
/// ```swift
/// let options = XMLTVOptions(channelIDs: ["BBC.One.uk"], timeWindow: .now ..< .now + 86_400)
/// let guide = try XMLTVDocument(contentsOf: url, options: options)
/// ```
///
/// ``parallelism`` and ``fileAccess`` apply only to ``XMLTVDocument``, and
/// ``maximumRecordSize`` only to streaming. Everything else applies to all three entry points.
public struct XMLTVOptions: Sendable, Hashable {
    /// How to treat problems with content, as opposed to markup.
    @nonexhaustive
    public enum Policy: Sendable, Hashable {
        /// Recover what can be recovered and record a ``XMLTVDiagnostic``. Bad values are dropped
        /// or repaired. For a file cut off mid-download, every complete record is kept. Broken
        /// markup in the middle of a document still throws.
        case lenient
        /// Throw on the first problem of any kind.
        case strict
    }

    /// How many threads ``XMLTVDocument`` may use, to read a file and to parse it. The result is
    /// identical for every setting.
    @nonexhaustive
    public enum Parallelism: Sendable, Hashable {
        /// Parallel for inputs of 1 MiB or more, on every available core.
        case automatic
        /// One thread.
        case serial
        /// At most this many threads, for inputs large enough to split.
        case threads(Int)

        /// The threads to use for reading and parsing. More threads than cores would only add
        /// contention; the cap also keeps `.threads(.max)`, a natural way to write "no limit",
        /// from overflowing the chunk arithmetic.
        var threadCount: Int {
            switch self {
            case .serial: 1
            case .threads(let n): max(1, min(n, ProcessInfo.processInfo.activeProcessorCount))
            case .automatic: ProcessInfo.processInfo.activeProcessorCount
            }
        }
    }

    /// How ``XMLTVDocument/init(contentsOf:options:)`` gets a file's bytes.
    @nonexhaustive
    public enum FileAccess: Sendable, Hashable {
        /// Read the file into memory. Safe even if another process rewrites the file meanwhile.
        case read
        /// Map the file into memory. This avoids one copy, but the process crashes (SIGBUS) if
        /// another process truncates the file during the parse. Use it only for files nothing
        /// else writes to, or that are replaced by an atomic rename.
        case memoryMapped
    }

    /// Whether problems with content are recovered or thrown. See ``Policy``.
    public var policy: Policy = .lenient

    /// Keep only these channels and their programmes. The test is made on the raw attribute
    /// before anything else is decoded, so programmes for other channels are skipped at
    /// scanning speed.
    public var channelIDs: Set<String>?

    /// Keep only programmes whose `start ..< stop` overlaps this interval. A programme with no
    /// `stop`, or with a time that cannot be compared exactly, is kept whenever it may overlap,
    /// so the result can include programmes that turn out to lie outside the window.
    ///
    /// The window is half-open, so an empty window, such as `date ..< date`, keeps no programmes.
    /// For "from now on", write `.now ..< .distantFuture`; for a `DateInterval`, write
    /// `interval.start ..< interval.end`.
    ///
    /// The window drops the programme after it, which ``XMLTVSchedule`` would need to work out
    /// when a last programme without a `stop` ends. For feeds that leave stops out, filter by
    /// channel only and ask the schedule about times.
    public var timeWindow: Range<Date>?

    /// How many threads ``XMLTVDocument`` may use.
    public var parallelism: Parallelism = .automatic
    /// How ``XMLTVDocument`` loads files. Reading is the default because it is safe against other
    /// processes rewriting the file, and as fast as mapping.
    public var fileAccess: FileAccess = .read

    /// Overrides the encoding the document declares. Use this for feeds that mislabel themselves.
    public var encoding: XMLTVEncoding?

    /// UTC offsets, in seconds, for zone names in timestamps (`20020517020200 BST`). XMLTV has no
    /// registry of names, and many are ambiguous (`IST`, `CST`), so the defaults are few: UTC,
    /// GMT, Z, and BST as British Summer Time, the meaning in XMLTV's own UK-centric tools
    /// (Bangladesh also uses the abbreviation). A name that is missing yields a diagnostic, and the
    /// time is read as UTC. Names are matched exactly, then in upper case.
    public var namedTimeZones: [String: Int] = Self.standardNamedTimeZones

    /// The most diagnostics kept in ``XMLTVReport/diagnostics``. All of them are counted, in
    /// ``XMLTVReport/diagnosticCount`` and ``XMLTVReport/diagnosticCountsByCode``.
    public var diagnosticLimit = 100

    /// The largest single construct ``XMLTVReader`` and ``XMLTVItems`` hold while it arrives, in
    /// bytes of UTF-8: a channel or programme record, an element they skip, a comment, or text
    /// between records other than whitespace. Anything larger throws
    /// ``XMLTVError/Kind/recordTooLarge(maximumSize:)``, whatever the policy.
    ///
    /// This is what bounds a streaming parse's memory: the window holds about one construct, and
    /// may grow to twice this size while one arrives. A real programme record is a few kilobytes,
    /// so the default of 16 MiB is never reached by a guide, only by input built to exhaust
    /// memory, such as a small gzip file that expands to gigabytes of one comment.
    /// ``XMLTVDocument`` holds its whole input in any case, and does not apply this limit to a
    /// file or `Data`.
    public var maximumRecordSize = 16 << 20

    /// The default ``namedTimeZones``: UTC, GMT and Z as UTC, and BST as UTC+1.
    public static let standardNamedTimeZones: [String: Int] = ["UTC": 0, "GMT": 0, "Z": 0, "BST": 3600]

    public init(
        policy: Policy = .lenient,
        channelIDs: Set<String>? = nil,
        timeWindow: Range<Date>? = nil,
        parallelism: Parallelism = .automatic,
        fileAccess: FileAccess = .read,
        encoding: XMLTVEncoding? = nil,
        namedTimeZones: [String: Int] = Self.standardNamedTimeZones,
        diagnosticLimit: Int = 100,
        maximumRecordSize: Int = 16 << 20
    ) {
        self.policy = policy
        self.channelIDs = channelIDs
        self.timeWindow = timeWindow
        self.parallelism = parallelism
        self.fileAccess = fileAccess
        self.encoding = encoding
        self.namedTimeZones = namedTimeZones
        self.diagnosticLimit = diagnosticLimit
        self.maximumRecordSize = maximumRecordSize
    }
}

/// The text encodings the parser understands. Everything is converted to UTF-8 on input.
///
/// More encodings may be added in a minor release, so a `switch` needs `@unknown default`.
@nonexhaustive
public enum XMLTVEncoding: String, Sendable, Hashable, Codable {
    case utf8 = "UTF-8"
    case utf16LittleEndian = "UTF-16LE"
    case utf16BigEndian = "UTF-16BE"
    /// Exact ISO-8859-1: every byte is the code point of the same value.
    case latin1 = "ISO-8859-1"
    case latin9 = "ISO-8859-15"
    case windows1252 = "windows-1252"
}
