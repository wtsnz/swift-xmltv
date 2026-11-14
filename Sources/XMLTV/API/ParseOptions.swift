import Foundation

/// Options shared by ``XMLTVDocument`` and ``XMLTVReader``.
public struct ParseOptions: Sendable {
    /// How to treat problems with content, as opposed to markup.
    public enum Policy: Sendable, Hashable {
        /// Recover what can be recovered and record a ``XMLTVDiagnostic``. Bad values are dropped
        /// or repaired. For a file cut off mid-download, every complete record is kept. Broken
        /// markup in the middle of a document still throws.
        case lenient
        /// Throw on the first problem of any kind.
        case strict
    }

    /// How many threads ``XMLTVDocument`` may use. The result is identical for every setting.
    public enum Parallelism: Sendable, Hashable {
        /// Parallel for inputs of 1 MiB or more, on every available core.
        case automatic
        /// One thread.
        case serial
        /// At most this many threads, for inputs large enough to split.
        case threads(Int)
    }

    /// How ``XMLTVDocument/init(contentsOf:options:)`` gets a file's bytes.
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
    /// `stop`, or with a time that cannot be compared exactly, is kept whenever it may overlap.
    public var timeWindow: Range<Date>?

    /// How many threads a whole-document parse may use.
    public var parallelism: Parallelism = .automatic
    /// How files are loaded. Reading is the default because it is safe against other processes
    /// rewriting the file, and as fast as mapping.
    public var fileAccess: FileAccess = .read

    /// Overrides the encoding the document declares. Use this for feeds that mislabel themselves.
    public var encoding: XMLTVEncoding?

    /// UTC offsets, in seconds, for zone names in timestamps (`20020517020200 BST`). XMLTV has no
    /// registry of names, and many are ambiguous (`IST`, `CST`), so the defaults are few: UTC,
    /// GMT, Z, and BST as British Summer Time, the meaning in XMLTV's own UK-centric tools
    /// (Bangladesh also uses the abbreviation). A name that is missing yields a diagnostic, and the
    /// time is read as UTC.
    public var namedTimeZones: [String: Int32] = ["UTC": 0, "GMT": 0, "Z": 0, "BST": 3600]

    /// The most diagnostics kept in ``ParseReport/diagnostics``. All of them are counted.
    public var diagnosticLimit = 100

    public init() {}
}

/// The text encodings the parser understands. Everything is converted to UTF-8 on input.
public enum XMLTVEncoding: String, Sendable, Hashable {
    case utf8 = "UTF-8"
    case utf16LittleEndian = "UTF-16LE"
    case utf16BigEndian = "UTF-16BE"
    /// Exact ISO-8859-1: every byte is the code point of the same value.
    case latin1 = "ISO-8859-1"
    case latin9 = "ISO-8859-15"
    case windows1252 = "windows-1252"
}
