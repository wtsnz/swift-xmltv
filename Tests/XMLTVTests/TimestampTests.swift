import Foundation
import Testing
@testable import XMLTV

@Suite("Timestamps")
struct TimestampTests {
    func parse(_ text: String, zones: [String: Int32] = XMLTVOptions().namedTimeZones) -> TimestampParser.Outcome {
        Array(text.utf8).withUnsafeBufferPointer { TimestampParser.parse($0, namedZones: zones) }
    }

    func valid(_ text: String) -> XMLTVTimestamp? {
        if case .valid(let timestamp) = parse(text) { return timestamp }
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
        guard case .unresolvedZone(let timestamp, let name) = parse("20020517020200 IST") else {
            Issue.record("IST must not be guessed"); return
        }
        #expect(name == "IST" && !timestamp.isTimeZoneKnown)
        guard case .valid(let custom) = parse("20020517020200 IST", zones: ["IST": 19800]) else {
            Issue.record("caller-supplied zone"); return
        }
        #expect(custom.utcOffsetSeconds == 19800)
    }

    @Test func outOfRangeTimeFieldsAreNormalisedNotRejected() {
        // 571 such stops occur in the 1.93 GB benchmark feed.
        guard case .normalized(let timestamp) = parse("20261113006000+0000") else { Issue.record("minute 60"); return }
        #expect(timestamp.secondsSince1970 == reference(2026, 11, 13, 1, 0, 0, offset: 0))
        guard case .normalized(let midnight) = parse("20261113240000 +0000") else { Issue.record("hour 24"); return }
        #expect(midnight.secondsSince1970 == reference(2026, 11, 14, 0, 0, 0, offset: 0))
    }

    @Test func rejectsInvalidValues() {
        for text in ["20240231120000 +0000", "20230229000000 +0000", "00000101000000 +0000", "20240101120000 +9960",
                     "20240101120000 +0000junk", "2024010112000 +0000", "", "abc", "20241301000000", "20240101616000"] {
            if case .invalid = parse(text) { continue }
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
}
