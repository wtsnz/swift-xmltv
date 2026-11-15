/// Parses XMLTV timestamps straight to an epoch instant. It uses no `Calendar`, `DateFormatter` or
/// time zone database.
///
/// Nearly every timestamp in real feeds has the form `YYYYMMDDhhmmss +HHMM`. The fast path
/// decodes it with two overlapping 8-byte loads and SWAR digit arithmetic, validates the civil
/// date, and computes the instant with Hinnant's `days_from_civil`. Every other form goes to the
/// slow path: truncated values, a missing zone, a named zone, or out-of-range fields such as
/// minute 60.
enum TimestampParser {
    enum Outcome {
        /// A well-formed value.
        case valid(XMLTVTimestamp)
        /// A value with an out-of-range time field (`hh` 24, `mm` 60 or `ss` 60). Such values occur
        /// in real feeds. The instant is computed linearly, so `20261113006000` means 01:00:00.
        case normalized(XMLTVTimestamp)
        /// A value with a zone name missing from the caller's table. The instant is as if UTC.
        /// `isNormalized` says whether a time field was also out of range.
        case unresolvedZone(XMLTVTimestamp, name: String, isNormalized: Bool)
        case invalid
    }

    static func parse(_ text: UnsafeBufferPointer<UInt8>, namedZones: [String: Int]) -> Outcome {
        if let fast = parseCommonForm(text) { return .valid(fast) }
        return parseGeneralForm(text, namedZones: namedZones)
    }

    // MARK: Fast path

    /// `YYYYMMDDhhmmss +HHMM` (20 bytes) or `YYYYMMDDhhmmss+HHMM` (19 bytes), fully validated.
    @inline(__always)
    static func parseCommonForm(_ text: UnsafeBufferPointer<UInt8>) -> XMLTVTimestamp? {
        let count = text.count
        guard count == 20 || count == 19, let p = text.baseAddress else { return nil }
        let sign = count == 20 ? 15 : 14
        guard count == 19 || p[14] == UInt8(ascii: " ") else { return nil }

        let raw = UnsafeRawPointer(p)
        guard let ymd = eightDigits(raw.loadUnaligned(as: UInt64.self)),
              let dhms = eightDigits(raw.loadUnaligned(fromByteOffset: 6, as: UInt64.self)),
              let offsetHours = twoDigits(p, sign &+ 1),
              let offsetMinutes = twoDigits(p, sign &+ 3)
        else { return nil }

        let year = ymd / 10_000, month = ymd / 100 % 100, day = ymd % 100
        let hms = dhms % 1_000_000
        let hour = hms / 10_000, minute = hms / 100 % 100, second = hms % 100
        guard year >= 1, (1...12).contains(month), day >= 1, day <= daysInMonth(month, year),
              hour < 24, minute < 60, second < 60, offsetHours < 24, offsetMinutes < 60
        else { return nil }

        let offset: Int
        switch p[sign] {
        case UInt8(ascii: "+"): offset = offsetHours &* 3600 &+ offsetMinutes &* 60
        case UInt8(ascii: "-"): offset = -(offsetHours &* 3600 &+ offsetMinutes &* 60)
        default: return nil
        }
        let local = daysFromCivil(Int64(year), month, day) &* 86_400 &+ Int64(hour &* 3600 &+ minute &* 60 &+ second)
        return XMLTVTimestamp(secondsSince1970: local &- Int64(offset), offset: Int32(offset))
    }

    /// Decodes 8 ASCII digits, first digit in the lowest byte, or returns nil if any byte is not
    /// a digit. This is the SWAR method from simdjson: three multiply-shift steps.
    @inline(__always)
    static func eightDigits(_ word: UInt64) -> Int? {
        let digits = word &- 0x3030_3030_3030_3030
        // Each byte must be in 0...9: no borrow from the subtraction, and adding 0x76 must not
        // set the high bit.
        guard (digits | (digits &+ 0x7676_7676_7676_7676)) & 0x8080_8080_8080_8080 == 0 else { return nil }
        var value = (digits &* 2561) &>> 8
        value = ((value & 0x00FF_00FF_00FF_00FF) &* 6_553_601) &>> 16
        value = ((value & 0x0000_FFFF_0000_FFFF) &* 42_949_672_960_001) &>> 32
        return Int(truncatingIfNeeded: value)
    }

    @inline(__always)
    static func twoDigits(_ p: UnsafePointer<UInt8>, _ index: Int) -> Int? {
        let tens = Int(p[index]) &- 48, ones = Int(p[index &+ 1]) &- 48
        guard (0...9).contains(tens), (0...9).contains(ones) else { return nil }
        return tens &* 10 &+ ones
    }

    // MARK: Slow path

    /// Accepts 4, 6, 8, 10, 12 or 14 digits, then optional whitespace and a numeric offset or a
    /// zone name. With no zone, the value is UTC.
    static func parseGeneralForm(_ text: UnsafeBufferPointer<UInt8>, namedZones: [String: Int]) -> Outcome {
        var i = 0, end = text.count
        while i < end && text[i].isXMLWhitespace { i += 1 }
        while end > i && text[end - 1].isXMLWhitespace { end -= 1 }

        let digitsStart = i
        while i < end && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[i]) { i += 1 }
        let digitCount = i - digitsStart
        let precision: XMLTVTimestamp.Precision
        switch digitCount {
        case 4: precision = .year
        case 6: precision = .month
        case 8: precision = .day
        case 10: precision = .hour
        case 12: precision = .minute
        case 14: precision = .second
        default: return .invalid
        }

        func field(_ index: Int, _ width: Int, default value: Int) -> Int {
            guard index + width <= digitCount else { return value }
            var result = 0
            for k in 0..<width { result = result * 10 + Int(text[digitsStart + index + k] - 48) }
            return result
        }
        let year = field(0, 4, default: 0), month = field(4, 2, default: 1), day = field(6, 2, default: 1)
        let hour = field(8, 2, default: 0), minute = field(10, 2, default: 0), second = field(12, 2, default: 0)
        guard year >= 1, (1...12).contains(month), day >= 1, day <= daysInMonth(month, year),
              hour <= 24, minute <= 60, second <= 60
        else { return .invalid }
        let isNormalized = hour == 24 || minute == 60 || second == 60

        while i < end && text[i].isXMLWhitespace { i += 1 }
        var offset = 0
        var unresolvedName: String?
        if i < end {
            let sign = text[i]
            if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                guard end - i == 5, let base = text.baseAddress,
                      let hours = twoDigits(base, i + 1), let minutes = twoDigits(base, i + 3),
                      hours < 24, minutes < 60
                else { return .invalid }
                offset = (hours * 3600 + minutes * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
            } else {
                // A zone name starts with a letter and has no digit before any `+` or `-`, as in
                // `BST` or `GMT+1`. That rejects near misses such as the ISO form
                // `20240101T120000Z`, whose `T120000Z` would otherwise be read as a name.
                guard Self.isZoneName(UnsafeBufferPointer(rebasing: text[i..<end])) else { return .invalid }
                let name = String(decoding: UnsafeBufferPointer(rebasing: text[i..<end]), as: UTF8.self)
                if let known = namedZones[name] ?? namedZones[name.uppercased()] {
                    offset = Int(Int32(clamping: known))
                } else {
                    unresolvedName = name
                }
            }
        }

        let local = daysFromCivil(Int64(year), month, day) * 86_400 + Int64(hour * 3600 + minute * 60 + second)
        let timestamp = XMLTVTimestamp(
            secondsSince1970: local - Int64(offset), offset: Int32(offset),
            precision: precision, isTimeZoneKnown: unresolvedName == nil)
        if let unresolvedName { return .unresolvedZone(timestamp, name: unresolvedName, isNormalized: isNormalized) }
        return isNormalized ? .normalized(timestamp) : .valid(timestamp)
    }

    static func isZoneName(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let first = bytes.first, (first | 0x20) >= UInt8(ascii: "a"), (first | 0x20) <= UInt8(ascii: "z") else {
            return false
        }
        for byte in bytes {
            if byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") { return true }
            if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") { return false }
            if byte.isXMLWhitespace { return false }
        }
        return true
    }

    // MARK: Civil calendar

    /// Days from 1970-01-01 to the given proleptic Gregorian date (Howard Hinnant). Years are
    /// `Int64` so that every year of an `Int64` instant fits, on 32-bit platforms too.
    @inline(__always)
    static func daysFromCivil(_ year: Int64, _ month: Int, _ day: Int) -> Int64 {
        let y = month <= 2 ? year &- 1 : year
        let era = (y >= 0 ? y : y &- 399) / 400
        let yearOfEra = y &- era &* 400
        let shiftedMonth: Int = month > 2 ? month &- 3 : month &+ 9   // March is 0
        let dayOfYear = Int64((153 &* shiftedMonth &+ 2) / 5 &+ day &- 1)
        let dayOfEra = yearOfEra &* 365 &+ yearOfEra / 4 &- yearOfEra / 100 &+ dayOfYear
        return era &* 146_097 &+ dayOfEra &- 719_468
    }

    /// The proleptic Gregorian date `days` after 1970-01-01 (Howard Hinnant). The inverse of
    /// ``daysFromCivil(_:_:_:)``.
    static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = Int((5 * dayOfYear + 2) / 153)
        let day = Int(dayOfYear) - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    @inline(__always)
    static func daysInMonth(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
