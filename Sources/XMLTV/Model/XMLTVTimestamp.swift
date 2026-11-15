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
    /// wrote no zone, which XMLTV defines as UTC. Values beyond the range of `Int32`, about 68
    /// years, are clamped to it.
    public var utcOffsetSeconds: Int {
        get { Int(offset) }
        set { offset = Int32(clamping: newValue) }
    }
    /// Stored in 32 bits, so that a timestamp is 16 bytes.
    private var offset: Int32
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

    public init(secondsSince1970: Int64, utcOffsetSeconds: Int = 0, precision: Precision = .second, isTimeZoneKnown: Bool = true) {
        self.init(secondsSince1970: secondsSince1970, offset: Int32(clamping: utcOffsetSeconds), precision: precision, isTimeZoneKnown: isTimeZoneKnown)
    }

    init(secondsSince1970: Int64, offset: Int32, precision: Precision = .second, isTimeZoneKnown: Bool = true) {
        self.secondsSince1970 = secondsSince1970
        self.offset = offset
        self.precision = precision
        self.isTimeZoneKnown = isTimeZoneKnown
    }

    /// The timestamp for a date, to the second, as written with the given offset. Fractions of
    /// a second are dropped, rounding towards the past, as XMLTV cannot express them. Dates
    /// beyond the range of `Int64` seconds, such as `distantFuture` scaled up, are clamped.
    public init(_ date: Date, utcOffsetSeconds: Int = 0) {
        self.init(secondsSince1970: Self.seconds(date, rounding: .down), utcOffsetSeconds: utcOffsetSeconds)
    }

    /// A date as whole seconds since 1970, rounded as given and clamped to `Int64`. Infinite
    /// dates clamp to the ends of the range, and NaN to zero, rather than trapping.
    static func seconds(_ date: Date, rounding rule: FloatingPointRoundingRule) -> Int64 {
        let seconds = date.timeIntervalSince1970.rounded(rule)
        if seconds.isNaN { return 0 }
        if seconds >= 0x1p63 { return .max }
        if seconds < -0x1p63 { return .min }
        return Int64(seconds)
    }

    /// The first second after the period this timestamp names: the next year for `2024`, the
    /// next day for `20240101`. For a timestamp of second precision, the next second. Saturates
    /// at the end of the `Int64` range.
    var periodEndSecondsSince1970: Int64 {
        func saturating(_ result: (partialValue: Int64, overflow: Bool)) -> Int64 {
            result.overflow ? .max : result.partialValue
        }
        switch precision {
        case .second: return saturating(secondsSince1970.addingReportingOverflow(1))
        case .minute: return saturating(secondsSince1970.addingReportingOverflow(60))
        case .hour: return saturating(secondsSince1970.addingReportingOverflow(3600))
        case .day: return saturating(secondsSince1970.addingReportingOverflow(86_400))
        case .month, .year:
            // Calendar arithmetic, in the written offset.
            let (year, month, _) = TimestampParser.civilFromDays(local.day)
            let next = precision == .year || month == 12 ? (year + 1, 1) : (year, month + 1)
            let days = TimestampParser.daysFromCivil(next.0, next.1, 1)
            return Int64(clamping: Int128(days) * 86_400 - Int128(utcOffsetSeconds))
        }
    }

    /// The day since 1970-01-01, and the second of that day, in the written offset. The offset is
    /// applied after splitting, so no value of the fields overflows.
    var local: (day: Int64, second: Int64) {
        var day = secondsSince1970 / 86_400
        var second = secondsSince1970 % 86_400 + Int64(utcOffsetSeconds)
        let carry = second >= 0 ? second / 86_400 : (second - 86_399) / 86_400
        day += carry
        second -= carry * 86_400
        return (day, second)
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
        namedTimeZones: [String: Int] = XMLTVOptions.standardNamedTimeZones
    ) throws(XMLTVError) {
        var utf8 = String(text)
        let outcome = utf8.withUTF8 { TimestampParser.parse($0, namedZones: namedTimeZones) }
        switch outcome {
        case .valid(let timestamp):
            self = timestamp
        case .normalized(let timestamp) where policy == .lenient,
             .unresolvedZone(let timestamp, _, _) where policy == .lenient:
            self = timestamp
        case .unresolvedZone(_, _, true):
            throw XMLTVError(.invalidTimestamp(String(text)))
        case .unresolvedZone(_, let name, false):
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
        isTimeZoneKnown ? TimeZone(secondsFromGMT: utcOffsetSeconds) : nil
    }

    /// Whether the two timestamps are the same instant, whatever offsets they were written with.
    public func isSameInstant(as other: XMLTVTimestamp) -> Bool {
        secondsSince1970 == other.secondsSince1970
    }

    /// Orders by instant first. The remaining fields only break ties, so that ordering agrees
    /// with `==`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.secondsSince1970 != rhs.secondsSince1970 { return lhs.secondsSince1970 < rhs.secondsSince1970 }
        if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
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
            utcOffsetSeconds: try container.decodeIfPresent(Int.self, forKey: .utcOffsetSeconds) ?? 0,
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
        let (days, seconds) = local
        let (year, month, day) = TimestampParser.civilFromDays(days)
        let hour = seconds / 3600, minute = seconds / 60 % 60, second = seconds % 60

        func two(_ value: some BinaryInteger) -> String { value < 10 ? "0\(value)" : "\(value)" }
        // Years before 1 are written as ISO 8601 writes them: 0 is 1 BC, and -1 is `-0001`.
        let digits = String(year.magnitude)
        var text = (year < 0 ? "-" : "") + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        if precision > .year { text += "-" + two(month) }
        if precision > .month { text += "-" + two(day) }
        guard precision > .day else {
            // A date has no time to put a zone on, but an unresolved name still changes it.
            return isTimeZoneKnown ? text : text + " (unresolved zone name, read as UTC)"
        }
        text += "T" + two(hour)
        if precision >= .minute { text += ":" + two(minute) }
        if precision >= .second { text += ":" + two(second) }

        if !isTimeZoneKnown { return text + "Z (unresolved zone name, read as UTC)" }
        if offset == 0 { return text + "Z" }
        // An offset with a seconds part, which a named zone can have, keeps it, so that the text
        // names the same instant.
        let magnitude = abs(utcOffsetSeconds)
        text += (offset < 0 ? "-" : "+") + two(magnitude / 3600) + ":" + two(magnitude / 60 % 60)
        return magnitude % 60 == 0 ? text : text + ":" + two(magnitude % 60)
    }
}
