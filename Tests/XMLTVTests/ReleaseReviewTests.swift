import Foundation
import Testing
@testable import XMLTV

/// One test per defect found in the release reviews of 942e256. Each asserts the corrected
/// behaviour, on every path that could disagree.
@Suite("Release review regressions")
struct ReleaseReviewTests {
    static let start = #"start="20240101120000 +0000""#
    static let strict = XMLTVOptions(policy: .strict)

    /// The report of a serial parse, a parse split at every given offset, and streams at several
    /// chunk sizes must all be equal. Returns the serial report.
    @discardableResult
    func expectSamePaths(_ xml: String, options: XMLTVOptions = XMLTVOptions(), splits: [Int] = [],
                         chunkSizes: [Int] = [1, 2, 3, 7, 64, 4096], sourceLocation: SourceLocation = #_sourceLocation) throws -> DocumentDriver.Output {
        let bytes = Array(xml.utf8)
        let serial = try parse(bytes, splits: [], options: options)
        for split in splits {
            let parallel = try parse(bytes, splits: [split], options: options)
            #expect(parallel.programmes == serial.programmes, "split \(split)", sourceLocation: sourceLocation)
            #expect(parallel.report == serial.report, "split \(split)", sourceLocation: sourceLocation)
        }
        for chunkSize in chunkSizes {
            let streamed = try streamDecode(bytes, chunkSize: chunkSize, options: options)
            #expect(sortedByKind(streamed.items) == serial.channels.map(XMLTVItem.channel) + serial.programmes.map(XMLTVItem.programme),
                    "chunk \(chunkSize)", sourceLocation: sourceLocation)
            #expect(streamed.report == serial.report, "chunk \(chunkSize)", sourceLocation: sourceLocation)
        }
        return serial
    }

    // MARK: Blockers

    @Test func strictStreamingAcceptsEntitiesAtEveryChunkBoundary() throws {
        let xml = document(programme("<title>Tom &amp; Jerry &#233;</title><desc>a &lt; b</desc>") + "\n" + programme(#"<title>x</title>"#, attributes: #"start="20240101120000 +0000" channel="c&amp;d""#))
        let whole = try parse(xml, options: Self.strict)
        #expect(whole.programmes[0].title == "Tom & Jerry é")
        let bytes = Array(xml.utf8)
        for chunkSize in 1...64 {
            let streamed = try streamDecode(bytes, chunkSize: chunkSize, options: Self.strict)
            #expect(streamed.items.count == 2 && streamed.report == whole.report, "chunk \(chunkSize)")
        }
    }

    @Test func emptyChannelIsMissingOnEveryPath() throws {
        let body = programme("<title>first</title>", attributes: #"start="20240101120000" channel="""#) + "\n"
            + programme("<title>second</title>", attributes: #"start="20240101120000" channel="x""#) + "\n"
            + programme("<title>third</title>", attributes: #"start="20240101120000" channel="""#)
        let xml = document(body)
        let third = Array(xml.utf8).indices.filter { Array(xml.utf8)[$0...].starts(with: Array("<programme".utf8)) }[2]
        let serial = try expectSamePaths(xml, splits: [third])
        #expect(serial.programmes.map(\.title) == ["second"])
        #expect(serial.report.droppedProgrammeCount == 2)
        #expect(serial.report.diagnostics.map(\.kind) == Array(repeating: .missingAttribute(element: "programme", attribute: "channel"), count: 2))
        #expect(throws: XMLTVError.self) { try parse(xml, options: Self.strict) }
    }

    @Test func truncatedGzipDoesNotReserveFromItsLastBytes() throws {
        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03]
        bytes += Array(repeating: 0x55, count: 16) + [0xFF, 0xFF, 0xFF, 0xFF]
        var output = ByteBuffer()
        _ = try bytes.withUnsafeBufferPointer { raw throws(XMLTVError) in try GzipInflater.inflateAll(raw, into: &output) }
        // The trailer says 4 GiB; the buffer is only ever one growth step past the hint.
        #expect(output.capacity < 1 << 20)
    }

    // MARK: Values that were dropped without a report

    @Test func yesNoValuesAreValidated() throws {
        let xml = document(programme(#"""
        <title>t</title><credits><actor guest="maybe">A</actor></credits><video><present>maybe</present><colour>yes!</colour></video><audio><present>nope</present></audio>
        """#))
        let report = try expectSamePaths(xml).report
        #expect(report.diagnostics.map(\.code) == [.invalidValue, .invalidValue, .invalidValue, .invalidValue])
        #expect(report.diagnostics.map(\.recovery) == [.assumedDefault, .valueDropped, .valueDropped, .valueDropped])
        #expect(throws: XMLTVError.self) { try parse(xml, options: Self.strict) }
        let guestBytes = Array("<tv><programme \(Self.start) channel=\"c\"><title>t</title><credits><actor guest=\"y".utf8)
            + [0xFF] + Array("s\">A</actor></credits></programme></tv>".utf8)
        #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(guestBytes), options: Self.strict) }
    }

    @Test func normalisedTimeWithUnknownZoneReportsBoth() throws {
        let report = try parse(document(programme("<title>t</title>", attributes: #"start="20240101246000 IST" channel="c""#))).report
        #expect(report.diagnostics.map(\.code) == [.invalidTimestamp, .unresolvedTimeZone])
        #expect(throws: XMLTVError(.invalidTimestamp("20240101246000 IST"))) { try XMLTVTimestamp("20240101246000 IST", policy: .strict) }
    }

    @Test func ratingTextIsGatheredWhole() throws {
        let xml = document(programme("<title>t</title><rating>1<!--split-->2</rating><rating><![CDATA[PG]]></rating><star-rating> 3/<![CDATA[5]]> </star-rating>"))
        let guide = try expectSamePaths(xml)
        #expect(guide.programmes[0].ratings.map(\.value) == ["12", "PG"])
        #expect(guide.programmes[0].starRatings.map(\.value) == ["3/5"])
        #expect(guide.report.diagnostics.map(\.recovery) == [.repaired, .repaired, .repaired])
    }

    // MARK: Well-formedness

    @Test func basicLexicalRulesAreChecked() throws {
        let filtered = XMLTVOptions(channelIDs: ["other"])
        for body in ["<1bad/>", #"<x ="v"/>"#, "<!-- a -- b -->", "<!DOCTYPE tv>", "<x><!-- a -- b --></x>", #"<x 1a="v"/>"#] {
            let xml = "<tv>\(body)</tv>"
            #expect(throws: XMLTVError.self, "\(body)") { try parse(xml) }
            #expect(throws: XMLTVError.self, "\(body)") { try parse(xml, options: filtered) }
            #expect(throws: XMLTVError.self, "\(body)") { try streamDecode(Array(xml.utf8), chunkSize: 3) }
        }
        // Allowed: a comment ending in `-->`, a DOCTYPE before the root, comments after it.
        let fine = "<?xml version=\"1.0\"?><!DOCTYPE tv><tv><!-- a - b --></tv><!-- after -->\n<?pi?>\n"
        #expect(try expectSamePaths(fine).report.diagnosticCount == 0)
    }

    @Test func errorPagesAreNotXMLTV() throws {
        let pages = [
            "<!doctype html>\n<html lang=\"en\"><body>x</body></html>",
            "<html lang=en><head><title>502</title></head></html>",
            "]]> not a guide",
        ]
        for page in pages {
            #expect("\(page)") { try parse(page) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
            #expect("\(page)") { try streamDecode(Array(page.utf8), chunkSize: 5) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
        }
    }

    @Test func anythingAfterTheRootIsOneDiagnostic() throws {
        for trailer in ["<a b=c>", "<!bogus>", "<", "<!-- unterminated", "  \n junk", "<![CDATA[x]]>"] {
            let xml = "<tv><programme \(Self.start) channel=\"c\"><title>t</title></programme></tv>\(trailer)"
            let report = try expectSamePaths(xml).report
            #expect(report.diagnostics.map(\.code) == [.contentAfterRoot], "\(trailer)")
            #expect(!report.isTruncated, "\(trailer)")
        }
        let report = try expectSamePaths("<tv/> \n junk").report
        #expect(report.diagnostics.map(\.line) == [2])
        #expect(report.diagnostics[0].byteOffset == "<tv/> \n ".utf8.count)
    }

    // MARK: Filters and detection

    @Test func timeWindowKeepsPartialTimesThatMayOverlap() throws {
        let june = Date(timeIntervalSince1970: 1_717_200_000)   // 2024-06-01
        let window = XMLTVOptions(timeWindow: june ..< june.addingTimeInterval(30 * 86_400))
        let xml = document("""
        <programme start="2023" stop="2024" channel="c"><title>may overlap</title></programme>
        <programme start="2023" stop="202405" channel="c"><title>ended in May</title></programme>
        <programme start="20240601120000 +0000" stop="2024060113" channel="c"><title>inside</title></programme>
        <programme start="20240801120000 +0000" channel="c"><title>after</title></programme>
        """)
        #expect(try parse(xml, options: window).programmes.map(\.title) == ["may overlap", "inside"])
        #expect(XMLTVTimestamp(secondsSince1970: 1_704_067_200, precision: .year).periodEndSecondsSince1970 == 1_735_689_600)
        #expect(XMLTVTimestamp(secondsSince1970: 1_733_011_200, precision: .month).periodEndSecondsSince1970 == 1_735_689_600)
    }

    @Test func excludedRecordsReportNothingWhateverTheFilter() throws {
        let june = Date(timeIntervalSince1970: 1_717_200_000)
        let xml = document(programme("<title>t</title>", attributes: #"start="20240101126000 +0000" stop="20240101130000 +0000" channel="c""#))
        let report = try parse(xml, options: XMLTVOptions(timeWindow: june ..< june.addingTimeInterval(86_400))).report
        #expect(report.diagnosticCount == 0)
    }

    @Test func longDeclarationStillDeclaresTheEncoding() throws {
        let head = "<?xml version=\"1.0\"" + String(repeating: " ", count: 2000) + "encoding=\"ISO-8859-1\"?>"
        let bytes = Array((head + "<tv><programme \(Self.start) channel=\"c\"><title>").utf8) + [0xE9] + Array("</title></programme></tv>".utf8)
        let guide = try XMLTVDocument(data: Data(bytes))
        #expect(guide.programmes[0].title == "é" && guide.report.encoding == .latin1)
        for chunkSize in [1, 100, 1500] {
            #expect(try streamDecode(bytes, chunkSize: chunkSize).items.count == 1)
        }
        let endless = Array("<?xml version=\"1.0\"".utf8) + Array(repeating: 0x20, count: 70_000)
        #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(endless)) }
    }

    @Test func nestedGzipIsNotXMLTVOnEveryPath() throws {
        let inner = try Fixtures.data("upstream_test.xml.gz")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID()).gz")
        try inner.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        let outer = try Data(contentsOf: URL(fileURLWithPath: url.path + ".gz"))
        try? FileManager.default.removeItem(atPath: url.path + ".gz")
        #expect { try XMLTVDocument(data: outer) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
        #expect { try streamDecode(Array(outer), chunkSize: 512) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
    }

    @Test func repeatedAttributesUseTheFirst() throws {
        let xml = #"<tv date="1" date="2"><programme start="20240101120000" start="20250101120000" channel="first" channel="last" clumpidx="0/2" clumpidx="1/2"><title>t</title></programme></tv>"#
        let guide = try parse(xml)
        #expect(guide.info.date == "1")
        #expect(guide.programmes[0].channelID == "first")
        #expect(guide.programmes[0].start.secondsSince1970 == 1_704_110_400)
        #expect(guide.programmes[0].clump == .init(index: 0, count: 2))
    }

    @Test func singleValuedChildrenUseTheFirst() throws {
        let xml = document(programme("""
        <title>t</title><length units="minutes">30</length><length units="minutes">60</length>\
        <language>en</language><language>fr</language><video><aspect>16:9</aspect></video><video><aspect>4:3</aspect></video>
        """))
        let programme = try parse(xml).programmes[0]
        #expect(programme.length == .seconds(1800) && programme.language?.value == "en" && programme.video?.aspect == "16:9")
    }

    @Test func lengthIsDecimal() throws {
        for (value, valid) in [("0x10", false), ("1e2", false), ("inf", false), ("2.5", true), ("1.2.3", false), ("90", true)] {
            let guide = try parse(document(programme("<title>t</title><length units=\"minutes\">\(value)</length>")))
            #expect((guide.programmes[0].length != nil) == valid, "\(value)")
        }
    }

    @Test func nearMissTimesAreInvalidNotZones() throws {
        for text in ["20240101T120000Z", "20240101120000 0100", "20240101120000 +01:00"] {
            #expect(throws: XMLTVError.self, "\(text)") { try XMLTVTimestamp(text, policy: .lenient) }
        }
        #expect(try XMLTVTimestamp("20240101120000 GMT+1", policy: .lenient).isTimeZoneKnown == false)
        #expect(try XMLTVTimestamp("20240101120000 Europe/London", policy: .lenient).isTimeZoneKnown == false)
    }

    // MARK: Locations

    @Test func carriageReturnsEndLines() throws {
        let xml = "<tv>\r<programme channel=\"c\"/>\r\n<programme channel=\"c\"/>\r</tv>"
        let report = try expectSamePaths(xml).report
        #expect(report.diagnostics.map(\.line) == [2, 3])
    }

    @Test func streamErrorsHaveTheDocumentColumn() throws {
        let xml = "<tv>" + String(repeating: "<x/>", count: 10_000) + "<y></z></tv>"
        var document: XMLTVError?
        do { _ = try parse(xml) } catch { document = error }
        for chunkSize in [64, 4096] {
            do {
                _ = try streamDecode(Array(xml.utf8), chunkSize: chunkSize)
                Issue.record("expected an error")
            } catch {
                #expect(error.line == document?.line && error.column == document?.column && error.byteOffset == document?.byteOffset)
            }
        }
    }

    @Test func parallelRepairKeepsItsSamples() throws {
        func prog(_ title: String, start: String = "20240101120000 +0000") -> String {
            "<programme start=\"\(start)\" channel=\"c1\"><title>\(title)</title></programme>\n"
        }
        var body = prog("real 0")
        body += "<!-- <programme start=\"20240101120000 +0000\" channel=\"fake\"><desc><![CDATA[ -->\n"
        body += prog("real A") + prog("real B")
        body += "<!-- ]]></desc></programme>\n"
        for _ in 0..<8 { body += "<programme start=\"bogus\" channel=\"ghost\"/>\n" }
        body += "-->\n"
        for i in 0..<6 { body += prog("real bad \(i)", start: "nonsense\(i)") }
        body += prog("real last")
        let xml = document(body)
        let bytes = Array(xml.utf8)
        let fake = bytes.indices.filter { bytes[$0...].starts(with: Array("<programme".utf8)) }[1]
        try expectSamePaths(xml, options: XMLTVOptions(diagnosticLimit: 4), splits: [fake], chunkSizes: [])
    }

    // MARK: Values that trapped

    @Test func extremeOptionsDoNotTrap() throws {
        let data = try Fixtures.data("upstream_test.xml")
        _ = try XMLTVDocument(data: data, options: XMLTVOptions(parallelism: .threads(.max)))
        for end in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .greatestFiniteMagnitude)] {
            _ = try XMLTVDocument(data: data, options: XMLTVOptions(timeWindow: Date.distantPast ..< end))
            _ = XMLTVSchedule(try XMLTVDocument(data: data)).current("c", at: end)
            #expect(XMLTVTimestamp(end).secondsSince1970 == .max)
        }
        let huge = try parse(document(#"<channel id="c"><display-name>C</display-name><icon src="i" width="99999999999999999999"/></channel>"#))
        #expect(huge.channels[0].icons[0].width == nil && huge.report.diagnosticCount == 1)
    }

    @Test func invalidScoresAndNegativeDurations() {
        #expect(Programme.StarRating("inf/inf").score == nil)
        #expect(Programme.StarRating("1/1e400").score == nil)
        let backwards = Programme(channelID: "c", start: XMLTVTimestamp(secondsSince1970: 3600), stop: XMLTVTimestamp(secondsSince1970: 0))
        #expect(backwards.duration == nil && backwards.dateInterval == nil)
    }

    // MARK: Persistence formats

    @Test func codableShapesAreStable() throws {
        func json<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        func roundTrips<T: Codable & Equatable>(_ value: T, as expected: String) throws {
            #expect(try json(value) == expected)
            #expect(try JSONDecoder().decode(T.self, from: Data(expected.utf8)) == value)
        }
        try roundTrips(XMLTVTimestamp(secondsSince1970: 1, utcOffsetSeconds: 3600, precision: .day, isTimeZoneKnown: false),
                       as: #"{"isTimeZoneKnown":false,"precision":"day","secondsSince1970":1,"utcOffsetSeconds":3600}"#)
        try roundTrips(LocalizedText("Hi", language: "en"), as: #"{"language":"en","value":"Hi"}"#)
        try roundTrips(Icon("a.png", width: 1, height: 2), as: #"{"height":2,"urlString":"a.png","width":1}"#)
        try roundTrips(URLReference("u", system: "imdb"), as: #"{"system":"imdb","urlString":"u"}"#)
        try roundTrips(Programme.Image("p.jpg", type: "poster", size: "2", orientation: "P", system: "tmdb"),
                       as: #"{"orientation":"P","size":"2","system":"tmdb","type":"poster","urlString":"p.jpg"}"#)
        try roundTrips(XMLTVSchedule.Entry.ID(channelID: "c", secondsSince1970: 5, ordinal: 1),
                       as: #"{"channelID":"c","ordinal":1,"secondsSince1970":5}"#)
        try roundTrips(XMLTVError.Code.invalidUTF8, as: #""invalidUTF8""#)
        try roundTrips(XMLTVDiagnostic.Recovery.programmeDropped, as: #""programmeDropped""#)
    }
}
