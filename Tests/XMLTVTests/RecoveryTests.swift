import Foundation
import Testing
@testable import XMLTV

/// Each kind of bad content is recovered by its fixed rule, reported with what it cost, and fatal in strict mode.
@Suite("Lenient recovery")
struct RecoveryTests {
    static let start = #"start="20240101120000 +0000""#
    static let strict = XMLTVOptions(policy: .strict)

    @Test func recoveriesAreClassifiedAndCounted() throws {
        let xml = document("""
        <channel><display-name>No id</display-name></channel>
        <channel id="c"><display-name>C</display-name></channel>
        <programme start="nonsense" channel="c"><title>Bad start</title></programme>
        <programme \(Self.start) channel="c"><title>t</title></programme>
        <programme \(Self.start) stop="nonsense" channel="c"><title>Bad stop</title></programme>
        <programme start="20240101126000 +0000" channel="c"><title>Minute 60</title></programme>
        <programme start="20240101120000 XYZ" channel="c"><title>Zone</title></programme>
        <programme \(Self.start) channel="c"></programme>
        <programme \(Self.start) channel="c"><title>t &bogus;</title></programme>
        """)
        let report = try parse(xml).report
        #expect(report.diagnostics.map(\.recovery) == [
            .channelDropped, .programmeDropped, .valueDropped, .repaired, .assumedDefault, .keptAsWritten, .keptAsWritten,
        ])
        #expect(report.droppedProgrammeCount == 1 && report.droppedChannelCount == 1)
        #expect(report.diagnosticCountsByCode == [
            .missingAttribute: 1, .invalidTimestamp: 3, .unresolvedTimeZone: 1, .missingElement: 1, .unsupportedEntity: 1,
        ])
        #expect(report.diagnosticCount == 7)
    }

    @Test func countsCoverDiagnosticsBeyondTheLimit() throws {
        var body = ""
        for i in 0..<50 { body += #"<programme start="bad\#(i)" channel="c"><title>t</title></programme>"# + "\n" }
        let xml = document(body)
        let options = XMLTVOptions(diagnosticLimit: 3)
        let report = try parse(xml, options: options).report
        #expect(report.diagnostics.count == 3)
        #expect(report.diagnosticCountsByCode == [.invalidTimestamp: 50] && report.droppedProgrammeCount == 50)

        // The same counts whatever the split or chunking.
        let bytes = Array(xml.utf8)
        for split in stride(from: 40, to: bytes.count, by: 397) {
            #expect(try parse(bytes, splits: [split], options: options).report == report, "split \(split)")
        }
        for chunkSize in [1, 13, 4096] {
            let streamed = try streamDecode(bytes, chunkSize: chunkSize, options: options).report
            #expect(streamed.diagnosticCountsByCode == report.diagnosticCountsByCode, "chunk \(chunkSize)")
            #expect(streamed.droppedProgrammeCount == 50)
        }
    }

    @Test func endOfInputProblemsCostTheRestOfTheInput() throws {
        let report = try parse("<tv><programme \(Self.start) channel=\"c\"><title>t</title></programme><programme").report
        #expect(report.diagnostics.last?.kind == .unexpectedEndOfInput)
        #expect(report.diagnostics.last?.recovery == .restOfInputIgnored)
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

    @Test func textWithBothProblemsReportsBoth() throws {
        let bytes = Array("<tv><programme start=\"2024\" channel=\"c\"><title>a".utf8) + [0x00, 0xFF] + Array("</title></programme></tv>".utf8)
        let report = try XMLTVDocument(data: Data(bytes)).report
        #expect(report.diagnostics.map(\.kind) == [.invalidCharacter(0), .invalidUTF8])
        #expect(report.diagnostics.map(\.recovery) == [.keptAsWritten, .repaired])
    }

    @Test func ratingTextIsGatheredWhole() throws {
        let xml = document(programme("<title>t</title><rating>1<!--split-->2</rating><rating><![CDATA[PG]]></rating><star-rating> 3/<![CDATA[5]]> </star-rating>"))
        let guide = try expectSamePaths(xml)
        #expect(guide.programmes[0].ratings.map(\.value) == ["12", "PG"])
        #expect(guide.programmes[0].starRatings.map(\.value) == ["3/5"])
        #expect(guide.report.diagnostics.map(\.recovery) == [.repaired, .repaired, .repaired])
    }

    /// Invalid bytes on either side of markup stay invalid: they must not join into one
    /// character, however the text is split.
    @Test func invalidUTF8InPiecesIsRepairedPieceByPiece() throws {
        let open = Array(#"<tv><programme start="20240101000000" channel="c">"#.utf8), close = Array("</programme></tv>".utf8)
        func around(_ before: String, _ between: String, _ after: String) -> [UInt8] {
            var bytes = open
            bytes += Array(before.utf8)
            bytes.append(0xC3)
            bytes += Array(between.utf8)
            bytes.append(0xA9)
            bytes += Array(after.utf8)
            return bytes + close
        }
        let replaced = "\u{FFFD}\u{FFFD}"
        let cases: [(document: [UInt8], title: String?, credit: String?, rating: String?)] = [
            (around("<title>", "<!--split-->", "</title>"), replaced, nil, nil),
            (around("<title>", "<![CDATA[", "]]></title>"), replaced, nil, nil),
            (around("<title>", "<b/>", "</title>"), replaced, nil, nil),
            (around("<title>t</title><credits><actor>", "<image>i</image>", "</actor></credits>"), "t", replaced, nil),
            (around("<title>t</title><rating>", "<!---->", "</rating>"), "t", nil, replaced),
        ]
        for (document, title, credit, rating) in cases {
            let guide = try expectSamePaths(bytes: document)
            let programme = guide.programmes[0]
            #expect(programme.title == title)
            #expect(programme.credits.first?.name == credit)
            #expect(programme.ratings.first?.value == rating)
            #expect(guide.report.diagnosticCountsByCode[.invalidUTF8] == 2)
            #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(document), options: Self.strict) }
        }
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

    /// Every single-valued child and attribute, nested ones included, keeps its first
    /// occurrence, even when that occurrence is invalid.
    @Test func firstOccurrenceWinsEverywhere() throws {
        let children = """
            <title>t</title>
            <length units="minutes">bad</length><length units="minutes">30</length>
            <video><present>maybe</present><present>yes</present><quality>FIRST</quality><quality>LAST</quality></video>
            <audio><stereo>FIRST</stereo><stereo>LAST</stereo></audio>
            <subtitles><language>FIRST</language><language>LAST</language></subtitles>
            <rating><value>FIRST</value><value>LAST</value></rating>
            <review type="text" type="url" source="FIRST" source="LAST">r</review>
            <image type="poster" type="backdrop" size="1" size="3">i</image>
            """
        let guide = try parse(document(programme(children, attributes: #"start="20240101120000" channel="c" clumpidx="bad" clumpidx="0/2""#)))
        let programme = guide.programmes[0]
        #expect(programme.length == nil)
        #expect(programme.video?.isPresent == nil && programme.video?.quality == "FIRST")
        #expect(programme.audio?.stereo == "FIRST")
        #expect(programme.subtitleTracks.first?.language?.value == "FIRST")
        #expect(programme.ratings.first?.value == "FIRST")
        #expect(programme.reviews.first?.type == "text" && programme.reviews.first?.source == "FIRST")
        #expect(programme.images.first?.type == "poster" && programme.images.first?.size == "1")
        #expect(programme.clump == .single)
        // The invalid first values are reported once each, and the later ones are not used.
        #expect(guide.report.diagnosticCountsByCode == [.invalidValue: 3])
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

    @Test func hugeValuesNeverTrap() throws {
        let length = try parse(document(programme(#"<title>t</title><length units="hours">1e308</length>"#)))
        #expect(length.programmes[0].length == nil && length.report.diagnosticCount == 1)
        let episode = try parse(document(programme(#"<title>t</title><episode-num system="xmltv_ns">9223372036854775807.0.</episode-num>"#)))
        #expect(episode.programmes[0].episodeNumbers[0].xmltvNS?.displaySeason == nil)
        #expect(Programme.EpisodeNumber.XMLTVNS("-1.0.0") == nil)
    }

    @Test func attributesAreComparedAfterDecoding() throws {
        let p = try parse(document(programme(#"""
        <title>t</title><credits><actor guest="y&#101;s">A</actor></credits><length units="minut&#101;s">2</length>
        """#))).programmes[0]
        #expect(p.credits[0].isGuest)
        #expect(p.length == .seconds(120))
    }

    @Test func numericReferencesMayHaveLeadingZeros() throws {
        let guide = try parse(document(programme("<title>&#00000000000065;&#x000000042;</title>")), options: Self.strict)
        #expect(guide.programmes[0].title == "AB")
    }

    @Test func cdataInMixedCreditsNormalisesLineEnds() throws {
        let guide = try parse(document(programme("<title>t</title><credits><actor><![CDATA[A &amp; B\rC]]></actor></credits>")))
        #expect(guide.programmes[0].credits[0].name == "A &amp; B\nC")
    }

    @Test func invalidScoresAndNegativeDurations() {
        #expect(Programme.StarRating("inf/inf").score == nil)
        #expect(Programme.StarRating("1/1e400").score == nil)
        let backwards = Programme(channelID: "c", start: XMLTVTimestamp(secondsSince1970: 3600), stop: XMLTVTimestamp(secondsSince1970: 0))
        #expect(backwards.duration == nil && backwards.dateInterval == nil)
    }
}
