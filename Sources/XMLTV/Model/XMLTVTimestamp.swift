import Foundation

/// A point in time as XMLTV writes it: `YYYYMMDDhhmmss ±HHMM`. Trailing fields may be left off,
/// and the zone may be omitted (meaning UTC) or named.
///
/// The value is 16 bytes and needs no allocation. It keeps the UTC instant, the offset that was
/// written, and how precise the source was. A year-only `date` stays distinct from midnight on
/// 1 January of that year.
public struct XMLTVTimestamp: Sendable, Hashable, Comparable {
    /// The instant, in seconds since 1970-01-01T00:00:00Z. For truncated values this is the start
    /// of the period: `2024` becomes 2024-01-01T00:00:00 in the given zone.
    public var secondsSince1970: Int64
    /// The UTC offset written in the source, in seconds east of Greenwich.
    public var utcOffsetSeconds: Int32
    /// The smallest unit the source specified.
    public var precision: Precision
    /// False when the source named a zone that is not in ``ParseOptions/namedTimeZones``. The
    /// instant was then computed as if the zone were UTC.
    public var isTimeZoneKnown: Bool

    /// The smallest unit a timestamp specifies. `.year` is the coarsest, `.second` the finest.
    public enum Precision: UInt8, Sendable, Hashable, Comparable {
        case year, month, day, hour, minute, second

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init(secondsSince1970: Int64, utcOffsetSeconds: Int32 = 0, precision: Precision = .second, isTimeZoneKnown: Bool = true) {
        self.secondsSince1970 = secondsSince1970
        self.utcOffsetSeconds = utcOffsetSeconds
        self.precision = precision
        self.isTimeZoneKnown = isTimeZoneKnown
    }

    /// The instant as a `Date`.
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(secondsSince1970)) }

    /// Orders by instant first. The remaining fields only break ties, so that ordering agrees
    /// with `==`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.secondsSince1970, lhs.utcOffsetSeconds, lhs.precision.rawValue, lhs.isTimeZoneKnown ? 1 : 0)
            < (rhs.secondsSince1970, rhs.utcOffsetSeconds, rhs.precision.rawValue, rhs.isTimeZoneKnown ? 1 : 0)
    }
}
