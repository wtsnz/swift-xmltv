import Foundation

/// A point in time as XMLTV writes it: `YYYYMMDDhhmmss ±HHMM`. Trailing fields may be left off,
/// and the zone may be omitted (meaning UTC) or named.
///
/// The value is 16 bytes and needs no allocation. It keeps the UTC instant, the offset that was
/// written, and how precise the source was. A year-only `date` stays distinct from midnight on
/// 1 January of that year.
///
/// ### Equality
///
/// Two timestamps are equal only when every field is: the same instant written with different
/// offsets, such as `20240101120000 +0000` and `20240101130000 +0100`, is two different
/// values. That keeps a parsed ``Programme`` equal to another only when the source said the
/// same thing. To compare instants, use ``isSameInstant(as:)`` or compare ``date``. Ordering
/// is by instant first, so sorting works as expected.
public struct XMLTVTimestamp: Sendable, Hashable, Comparable, Codable {
    /// The instant, in seconds since 1970-01-01T00:00:00Z. For truncated values this is the start
    /// of the period: `2024` becomes 2024-01-01T00:00:00 in the given zone.
    public var secondsSince1970: Int64
    /// The UTC offset written in the source, in seconds east of Greenwich. Zero when the source
    /// wrote no zone, which XMLTV defines as UTC.
    public var utcOffsetSeconds: Int32
    /// The smallest unit the source specified.
    public var precision: Precision
    /// False when the source named a zone that is not in ``XMLTVOptions/namedTimeZones``. The
    /// instant was then computed as if the zone were UTC.
    public var isTimeZoneKnown: Bool

    /// The smallest unit a timestamp specifies. `.year` is the coarsest, `.second` the finest.
    public enum Precision: String, Sendable, Hashable, Comparable, CaseIterable, Codable {
        case year, month, day, hour, minute, second

        private var order: Int {
            switch self {
            case .year: 0
            case .month: 1
            case .day: 2
            case .hour: 3
            case .minute: 4
            case .second: 5
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
    }

    public init(secondsSince1970: Int64, utcOffsetSeconds: Int32 = 0, precision: Precision = .second, isTimeZoneKnown: Bool = true) {
        self.secondsSince1970 = secondsSince1970
        self.utcOffsetSeconds = utcOffsetSeconds
        self.precision = precision
        self.isTimeZoneKnown = isTimeZoneKnown
    }

    /// The timestamp for a date, to the second, as written with the given offset. Fractions of
    /// a second are dropped, rounding towards the past, as XMLTV cannot express them.
    public init(_ date: Date, utcOffsetSeconds: Int32 = 0) {
        self.init(
            secondsSince1970: Int64(date.timeIntervalSince1970.rounded(.down)),
            utcOffsetSeconds: utcOffsetSeconds)
    }

    /// Parses XMLTV timestamp text, such as `20240101120000 +0100`, `2024` or
    /// `20020517020200 BST`.
    ///
    /// The rules are the parser's, and `policy` works as it does for a document. It has no
    /// default, because the two choices differ in what they hide: `.lenient` reads an unknown
    /// zone name as UTC without saying so.
    /// - Text that is not a timestamp always throws ``XMLTVError/Kind/invalidTimestamp(_:)``.
    /// - An out-of-range time such as minute 60 is normalised in `.lenient` mode, and throws
    ///   ``XMLTVError/Kind/invalidTimestamp(_:)`` in `.strict` mode.
    /// - A zone name missing from `namedTimeZones` is read as UTC, with ``isTimeZoneKnown``
    ///   false, in `.lenient` mode, and throws ``XMLTVError/Kind/unresolvedTimeZone(_:)`` in
    ///   `.strict` mode.
    public init(
        _ text: some StringProtocol,
        policy: XMLTVOptions.Policy,
        namedTimeZones: [String: Int32] = XMLTVOptions.standardNamedTimeZones
    ) throws(XMLTVError) {
        var utf8 = String(text)
        let outcome = utf8.withUTF8 { TimestampParser.parse($0, namedZones: namedTimeZones) }
        switch outcome {
        case .valid(let timestamp):
            self = timestamp
        case .normalized(let timestamp) where policy == .lenient,
             .unresolvedZone(let timestamp, _) where policy == .lenient:
            self = timestamp
        case .unresolvedZone(_, let name):
            throw XMLTVError(.unresolvedTimeZone(name))
        case .normalized, .invalid:
            throw XMLTVError(.invalidTimestamp(String(text)))
        }
    }

    @available(*, unavailable, message: "Choose how problems are handled: pass policy: .strict or policy: .lenient")
    public init(_ text: some StringProtocol) throws(XMLTVError) {
        fatalError("unavailable")
    }

    /// The instant as a `Date`.
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(secondsSince1970)) }

    /// The zone the source wrote, as a fixed offset from UTC. Use it to show a time as it was
    /// broadcast, rather than in the viewer's zone. Nil when the source named a zone that could
    /// not be resolved.
    ///
    /// The offset is only as good as the feed. Many feeds write every time in UTC, and then this
    /// is UTC, not the broadcaster's zone.
    public var timeZone: TimeZone? {
        isTimeZoneKnown ? TimeZone(secondsFromGMT: Int(utcOffsetSeconds)) : nil
    }

    /// Whether the two timestamps are the same instant, whatever offsets they were written with.
    public func isSameInstant(as other: XMLTVTimestamp) -> Bool {
        secondsSince1970 == other.secondsSince1970
    }

    /// Orders by instant first. The remaining fields only break ties, so that ordering agrees
    /// with `==`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.secondsSince1970 != rhs.secondsSince1970 { return lhs.secondsSince1970 < rhs.secondsSince1970 }
        if lhs.utcOffsetSeconds != rhs.utcOffsetSeconds { return lhs.utcOffsetSeconds < rhs.utcOffsetSeconds }
        if lhs.precision != rhs.precision { return lhs.precision < rhs.precision }
        return !lhs.isTimeZoneKnown && rhs.isTimeZoneKnown
    }

    // Encoded as an object with only the fields that differ from their defaults, such as
    // `{"secondsSince1970":1704110400}`. Every field but the instant is optional when decoding,
    // so a field added later can be read from data written before it existed.

    private enum CodingKeys: String, CodingKey {
        case secondsSince1970, utcOffsetSeconds, precision, isTimeZoneKnown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            secondsSince1970: try container.decode(Int64.self, forKey: .secondsSince1970),
            utcOffsetSeconds: try container.decodeIfPresent(Int32.self, forKey: .utcOffsetSeconds) ?? 0,
            precision: try container.decodeIfPresent(Precision.self, forKey: .precision) ?? .second,
            isTimeZoneKnown: try container.decodeIfPresent(Bool.self, forKey: .isTimeZoneKnown) ?? true)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(secondsSince1970, forKey: .secondsSince1970)
        if utcOffsetSeconds != 0 { try container.encode(utcOffsetSeconds, forKey: .utcOffsetSeconds) }
        if precision != .second { try container.encode(precision, forKey: .precision) }
        if !isTimeZoneKnown { try container.encode(isTimeZoneKnown, forKey: .isTimeZoneKnown) }
    }
}

extension XMLTVTimestamp: CustomStringConvertible {
    /// ISO 8601 in the written offset, to the precision of the source: `2024-05-17T02:02:00+01:00`,
    /// or `2024-05` for a month. An unresolved zone name is marked, since the time shown is UTC.
    public var description: String {
        let local = secondsSince1970 + Int64(utcOffsetSeconds)
        var days = local / 86_400, seconds = local % 86_400
        if seconds < 0 { days -= 1; seconds += 86_400 }
        let (year, month, day) = TimestampParser.civilFromDays(Int(days))
        let hour = seconds / 3600, minute = seconds / 60 % 60, second = seconds % 60

        func two(_ value: some BinaryInteger) -> String { value < 10 ? "0\(value)" : "\(value)" }
        var text = year < 1000 ? String(repeating: "0", count: 4 - String(year).count) + "\(year)" : "\(year)"
        guard precision > .year else { return text }
        text += "-" + two(month)
        guard precision > .month else { return text }
        text += "-" + two(day)
        guard precision > .day else { return text }
        text += "T" + two(hour)
        if precision >= .minute { text += ":" + two(minute) }
        if precision >= .second { text += ":" + two(second) }

        if !isTimeZoneKnown { return text + "Z (unresolved zone name, read as UTC)" }
        if utcOffsetSeconds == 0 { return text + "Z" }
        let magnitude = abs(Int(utcOffsetSeconds))
        return text + (utcOffsetSeconds < 0 ? "-" : "+") + two(magnitude / 3600) + ":" + two(magnitude / 60 % 60)
    }
}
