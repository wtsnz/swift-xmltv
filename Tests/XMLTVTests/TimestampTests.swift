import Foundation
import Testing
@testable import XMLTV

/// The timestamp parser against `Calendar`, and the public timestamp value: formatting, ordering,
/// extremes and its encoded form.
@Suite("Timestamps")
struct TimestampTests {
    static let start = #"start="20240101120000 +0000""#

    func outcome(_ text: String, zones: [String: Int32] = XMLTVOptions().namedTimeZones) -> TimestampParser.Outcome {
        Array(text.utf8).withUnsafeBufferPointer { TimestampParser.parse($0, namedZones: zones) }
    }

    func valid(_ text: String) -> XMLTVTimestamp? {
        if case .valid(let timestamp) = outcome(text) { return timestamp }
        return nil
    }

    /// Calendar is the oracle: slow, but independent of the parser's arithmetic.
    func reference(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, offset: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset)!
        let date = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
        return Int64(date.timeIntervalSince1970)
    }

    @Test func commonFormMatchesCalendar() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let y = Int.random(in: 1900...2100, using: &generator), mo = Int.random(in: 1...12, using: &generator)
            let d = Int.random(in: 1...TimestampParser.daysInMonth(mo, y), using: &generator)
            let h = Int.random(in: 0...23, using: &generator), mi = Int.random(in: 0...59, using: &generator)
            let s = Int.random(in: 0...59, using: &generator)
            let offsetMinutes = Int.random(in: -14 * 60...14 * 60, using: &generator)
            let sign = offsetMinutes < 0 ? "-" : "+"
            let zone = String(format: "%@%02d%02d", sign, abs(offsetMinutes) / 60, abs(offsetMinutes) % 60)
            let digits = String(format: "%04d%02d%02d%02d%02d%02d", y, mo, d, h, mi, s)
            let expected = reference(y, mo, d, h, mi, s, offset: offsetMinutes * 60)
            for text in ["\(digits) \(zone)", "\(digits)\(zone)"] {
                guard let timestamp = valid(text) else { Issue.record("rejected \(text)"); continue }
                #expect(timestamp.secondsSince1970 == expected, "\(text)")
                #expect(timestamp.utcOffsetSeconds == Int32(offsetMinutes * 60))
                #expect(timestamp.precision == .second && timestamp.isTimeZoneKnown)
            }
        }
    }

    @Test func truncatedValuesKeepTheirPrecision() {
        let cases: [(String, XMLTVTimestamp.Precision, Int64)] = [
            ("2008", .year, reference(2008, 1, 1, 0, 0, 0, offset: 0)),
            ("200807", .month, reference(2008, 7, 1, 0, 0, 0, offset: 0)),
            ("20080715", .day, reference(2008, 7, 15, 0, 0, 0, offset: 0)),
            ("2008071503", .hour, reference(2008, 7, 15, 3, 0, 0, offset: 0)),
            ("200807150330 -0600", .minute, reference(2008, 7, 15, 3, 30, 0, offset: -21600)),
        ]
        for (text, precision, seconds) in cases {
            let timestamp = valid(text)
            #expect(timestamp?.precision == precision, "\(text)")
            #expect(timestamp?.secondsSince1970 == seconds, "\(text)")
        }
    }

    @Test func namedZones() {
        #expect(valid("20020517020200 BST")?.secondsSince1970 == reference(2002, 5, 17, 2, 2, 0, offset: 3600))
        #expect(valid("20020517020200 UTC")?.utcOffsetSeconds == 0)
        guard case .unresolvedZone(let timestamp, let name, false) = outcome("20020517020200 IST") else {
            Issue.record("IST must not be guessed"); return
        }
        #expect(name == "IST" && !timestamp.isTimeZoneKnown)
        guard case .valid(let custom) = outcome("20020517020200 IST", zones: ["IST": 19800]) else {
            Issue.record("caller-supplied zone"); return
        }
        #expect(custom.utcOffsetSeconds == 19800)
    }

    @Test func outOfRangeTimeFieldsAreNormalisedNotRejected() {
        // 571 such stops occur in the 1.93 GB benchmark feed.
        guard case .normalized(let timestamp) = outcome("20261113006000+0000") else { Issue.record("minute 60"); return }
        #expect(timestamp.secondsSince1970 == reference(2026, 11, 13, 1, 0, 0, offset: 0))
        guard case .normalized(let midnight) = outcome("20261113240000 +0000") else { Issue.record("hour 24"); return }
        #expect(midnight.secondsSince1970 == reference(2026, 11, 14, 0, 0, 0, offset: 0))
    }

    @Test func rejectsInvalidValues() {
        for text in ["20240231120000 +0000", "20230229000000 +0000", "00000101000000 +0000", "20240101120000 +9960",
                     "20240101120000 +0000junk", "2024010112000 +0000", "", "abc", "20241301000000", "20240101616000"] {
            if case .invalid = outcome(text) { continue }
            Issue.record("accepted \(text)")
        }
        #expect(valid("20240229000000 +0000") != nil, "leap day")
    }

    @Test func swarDigitsAgreeWithScalarDecoding() {
        for value in stride(from: 0, through: 99_999_999, by: 9_973) {
            let text = String(format: "%08d", value)
            let word = Array(text.utf8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            #expect(TimestampParser.eightDigits(word) == value)
        }
        for bad in ["1234567/", "1234567:", "12 45678", "abcdefgh"] {
            let word = Array(bad.utf8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            #expect(TimestampParser.eightDigits(word) == nil, "\(bad)")
        }
    }

    @Test func orderingIsByInstant() {
        let a = valid("20240101120000 +0100")!, b = valid("20240101120000 +0000")!
        #expect(a < b)
        #expect([b, a].sorted() == [a, b])
    }

    @Test func timestampsParseFormatAndCompare() throws {
        let noon = try XMLTVTimestamp("20240101120000 +0000", policy: .strict)
        let oneLater = try XMLTVTimestamp("20240101130000 +0100", policy: .strict)
        #expect(noon != oneLater && noon.isSameInstant(as: oneLater) && noon.date == oneLater.date)
        #expect(noon < oneLater)
        #expect(oneLater.description == "2024-01-01T13:00:00+01:00")
        #expect(oneLater.timeZone == TimeZone(secondsFromGMT: 3600))
        #expect(try XMLTVTimestamp("2024", policy: .strict).description == "2024")
        #expect(try XMLTVTimestamp("200405", policy: .strict).description == "2004-05")
        #expect(try XMLTVTimestamp("20240101 -0530", policy: .strict).description == "2024-01-01")
        #expect(try XMLTVTimestamp("202401011205 -0530", policy: .strict).description == "2024-01-01T12:05-05:30")
        #expect(try XMLTVTimestamp("20020517020200 BST", policy: .strict).utcOffsetSeconds == 3600)

        #expect(throws: XMLTVError(.invalidTimestamp("20x4"))) { try XMLTVTimestamp("20x4", policy: .strict) }
        #expect(throws: XMLTVError(.unresolvedTimeZone("IST"))) { try XMLTVTimestamp("20240101120000 IST", policy: .strict) }
        #expect(throws: XMLTVError(.invalidTimestamp("20240101126000"))) { try XMLTVTimestamp("20240101126000", policy: .strict) }
        let lenientZone = try XMLTVTimestamp("20240101120000 IST", policy: .lenient)
        #expect(!lenientZone.isTimeZoneKnown && lenientZone.timeZone == nil)
        #expect(try XMLTVTimestamp("20240101126000", policy: .lenient) == XMLTVTimestamp("20240101130000", policy: .strict))

        let date = Date(timeIntervalSince1970: 1_700_000_000.75)
        #expect(XMLTVTimestamp(date).secondsSince1970 == 1_700_000_000)
        #expect(XMLTVTimestamp(Date(timeIntervalSince1970: -0.5)).secondsSince1970 == -1)
        #expect(XMLTVTimestamp.Precision.allCases.sorted() == XMLTVTimestamp.Precision.allCases)
    }

    @Test func descriptionIsCorrectAcrossTheCalendar() {
        // Every 97th day for about 900 years, checked against Foundation. Foundation's Gregorian
        // calendar switches to Julian dates before 1582, so the range starts after that.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for days in stride(from: -140_000, through: 200_000, by: 97) {
            let seconds = Int64(days) * 86_400 + 3723
            let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
            let expected = String(format: "%04d-%02d-%02dT01:02:03Z", parts.year!, parts.month!, parts.day!)
            #expect(XMLTVTimestamp(secondsSince1970: seconds).description == expected)
        }
    }

    /// Every value the initializers and `Codable` accept can be shown and measured.
    @Test func extremeTimestampsDoNotTrap() throws {
        #expect(XMLTVTimestamp(secondsSince1970: -62_198_755_200).description == "-0001-01-01T00:00:00Z")
        #expect(XMLTVTimestamp(secondsSince1970: -62_167_219_200).description == "0000-01-01T00:00:00Z")
        let extremes = [
            XMLTVTimestamp(secondsSince1970: .max, utcOffsetSeconds: 3600),
            XMLTVTimestamp(secondsSince1970: .min, utcOffsetSeconds: -3600),
            XMLTVTimestamp(secondsSince1970: .max, utcOffsetSeconds: .max, precision: .year),
            XMLTVTimestamp(secondsSince1970: .min, utcOffsetSeconds: .min, precision: .month),
            XMLTVTimestamp(Date(timeIntervalSince1970: -.infinity), utcOffsetSeconds: -3600),
            XMLTVTimestamp(Date(timeIntervalSince1970: .infinity), utcOffsetSeconds: 3600),
            XMLTVTimestamp(Date(timeIntervalSince1970: -93_724_000_000)),
            try JSONDecoder().decode(XMLTVTimestamp.self, from: Data(#"{"secondsSince1970":-9223372036854775808}"#.utf8)),
        ]
        for timestamp in extremes {
            #expect(!timestamp.description.isEmpty)
            #expect(timestamp.periodEndSecondsSince1970 >= timestamp.secondsSince1970)
        }
        let longest = Programme(channelID: "c", start: XMLTVTimestamp(secondsSince1970: .min), stop: XMLTVTimestamp(secondsSince1970: .max))
        #expect(longest.duration == .seconds(Int64.max) + .seconds(Int64.max) + .seconds(1))
    }

    @Test func leafValuesRoundTripThroughJSON() throws {
        let timestamp = XMLTVTimestamp(secondsSince1970: 1_700_000_000, utcOffsetSeconds: -18_000, precision: .minute, isTimeZoneKnown: false)
        let json = String(decoding: try JSONEncoder().encode(timestamp), as: UTF8.self)
        #expect(json.contains(#""precision":"minute""#))
        #expect(try JSONDecoder().decode(XMLTVTimestamp.self, from: Data(json.utf8)) == timestamp)
        let values = (LocalizedText("Hi", language: "en"), Icon("a.png", width: 1), URLReference("u", system: "s"))
        #expect(try JSONDecoder().decode(LocalizedText.self, from: JSONEncoder().encode(values.0)) == values.0)
        #expect(try JSONDecoder().decode(Icon.self, from: JSONEncoder().encode(values.1)) == values.1)
        #expect(try JSONDecoder().decode(URLReference.self, from: JSONEncoder().encode(values.2)) == values.2)
    }

    @Test func timestampJSONLeavesOutDefaults() throws {
        let plain = XMLTVTimestamp(secondsSince1970: 1_704_110_400)
        #expect(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self) == #"{"secondsSince1970":1704110400}"#)
        #expect(try JSONDecoder().decode(XMLTVTimestamp.self, from: Data(#"{"secondsSince1970":1704110400}"#.utf8)) == plain)
    }

    @Test func productionAndCreationDatesKeepPrecision() throws {
        let guide = try parse(#"<tv date="20240102"><programme \#(Self.start) channel="c"><title>t</title><date>1999</date></programme></tv>"#)
        #expect(guide.programmes[0].productionDate == XMLTVTimestamp(secondsSince1970: 915_148_800, precision: .year))
        #expect(guide.info.creationDate?.precision == .day)
    }
}
