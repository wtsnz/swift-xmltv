import Foundation
import Testing
@testable import XMLTV

/// Filtered records are skipped before they are decoded, and report nothing.
@Suite("Channel and time filters")
struct FilterTests {
    @Test func filtersByChannelAndTime() throws {
        let xml = document("""
        <channel id="a"><display-name>A</display-name></channel><channel id="b"><display-name>B</display-name></channel>
        \(programme("<title>a1</title>", attributes: #"start="20240101100000 +0000" stop="20240101110000 +0000" channel="a""#))
        \(programme("<title>b1</title>", attributes: #"start="20240101100000 +0000" stop="20240101110000 +0000" channel="b""#))
        \(programme("<title>a2</title>", attributes: #"start="20240101110000 +0000" stop="20240101120000 +0000" channel="a""#))
        \(programme("<title>a3</title>", attributes: #"start="20240101113000 +0000" channel="a""#))
        """)
        let byChannel = try parse(xml, options: .with { $0.channelIDs = ["a"] })
        #expect(byChannel.channels.map(\.id) == ["a"])
        #expect(byChannel.programmes.map(\.title) == ["a1", "a2", "a3"])

        let start = Date(timeIntervalSince1970: TimeInterval(1_704_103_200))   // 2024-01-01T10:00Z
        let byTime = try parse(xml, options: .with { $0.timeWindow = start.addingTimeInterval(3600)..<start.addingTimeInterval(7200) })
        #expect(byTime.programmes.map(\.title) == ["a2", "a3"])
    }

    /// An empty window overlaps nothing, even with fractional bounds, a missing stop or an
    /// unknown zone, all of which otherwise keep a programme that may overlap.
    @Test func emptyTimeWindowKeepsNothing() throws {
        let xml = document("""
            \(programme("<title>a</title>", attributes: #"start="20240101120000 +0000" stop="20240101130000 +0000" channel="c""#))
            \(programme("<title>b</title>", attributes: #"start="20240101120000 +0000" channel="c""#))
            \(programme("<title>c</title>", attributes: #"start="20240101120000 XYZ" channel="c""#))
            """)
        for seconds in [1_704_112_200.0, 1_704_112_200.5] {
            let point = Date(timeIntervalSince1970: seconds)
            let options = XMLTVOptions(timeWindow: point..<point)
            #expect(try parse(xml, options: options).programmes.isEmpty)
            #expect(try streamDecode(Array(xml.utf8), chunkSize: 7, options: options).items.isEmpty)
        }
    }

    /// A channel with no ID, or an empty one, is dropped and reported, unless a channel filter
    /// is on: then it could never be selected, and is skipped like any excluded channel.
    @Test func channelsWithoutAnIDFollowTheProgrammeRule() throws {
        let xml = document(#"<channel><display-name>A</display-name></channel><channel id=""><display-name>B</display-name></channel>"#)
        let unfiltered = try parse(xml)
        #expect(unfiltered.channels.isEmpty && unfiltered.report.droppedChannelCount == 2)
        #expect(unfiltered.report.diagnosticCountsByCode == [.missingAttribute: 2])
        let filtered = try parse(xml, options: XMLTVOptions(channelIDs: ["c"]))
        #expect(filtered.channels.isEmpty && filtered.report.diagnosticCount == 0)
    }

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

    @Test func excludedRecordsReportNothing() throws {
        let xml = document(#"""
        <channel id="x&bogus;"><display-name>X</display-name></channel>
        <programme channel="x&bogus;" start="20240101120000"><title>t</title></programme>
        """#)
        #expect(try parse(xml, options: XMLTVOptions(channelIDs: ["c"])).report.diagnosticCount == 0)
        #expect(try parse(xml).report.diagnosticCount == 2)
        #expect(XMLTVError.Kind.missingAttribute(element: "icon", attribute: "src").message == "An <icon> has no “src” attribute.")
        #expect(XMLTVDiagnostic(kind: .invalidUTF8, recovery: .repaired).description == "invalidUTF8 (repaired)")
    }

    @Test func excludedRecordsReportNothingWhateverTheFilter() throws {
        let june = Date(timeIntervalSince1970: 1_717_200_000)
        let xml = document(programme("<title>t</title>", attributes: #"start="20240101126000 +0000" stop="20240101130000 +0000" channel="c""#))
        let report = try parse(xml, options: XMLTVOptions(timeWindow: june ..< june.addingTimeInterval(86_400))).report
        #expect(report.diagnosticCount == 0)
    }

    @Test func excludedChannelsAreNotCounted() throws {
        let xml = document(#"""
        <programme channel="excluded"><title>t</title></programme>
        <programme channel="excluded" start="bad"><title>t</title></programme>
        <programme start="20240101120000"><title>no channel</title></programme>
        <programme channel="c"><title>no start</title></programme>
        """#)
        let filtered = try parse(xml, options: XMLTVOptions(channelIDs: ["c"])).report
        #expect(filtered.droppedProgrammeCount == 1 && filtered.diagnosticCount == 1)
        let all = try parse(xml).report
        #expect(all.droppedProgrammeCount == 4)
    }
}
