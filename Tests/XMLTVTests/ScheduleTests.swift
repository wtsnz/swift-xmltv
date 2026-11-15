import Foundation
import Testing
@testable import XMLTV

/// Sorting, duplicates, inferred ends, identity, and what is on now and next.
@Suite("Schedule")
struct ScheduleTests {
    static let start = #"start="20240101120000 +0000""#

    func time(_ hour: Int, _ minute: Int = 0) -> XMLTVTimestamp {
        XMLTVTimestamp(secondsSince1970: Int64(hour * 3600 + minute * 60))
    }

    func date(_ hour: Int, _ minute: Int = 0) -> Date { time(hour, minute).date }

    @Test func scheduleInfersMissingStopsAndSorts() {
        let programmes = [
            Programme(channelID: "c", start: time(11), title: "Eleven"),
            Programme(channelID: "c", start: time(10), title: "Ten"),
            Programme(channelID: "c", start: time(12), title: "Twelve"),
            Programme(channelID: "d", start: time(10), stop: time(10, 30), title: "Short"),
        ]
        let schedule = XMLTVSchedule(programmes: programmes)
        #expect(schedule.channelIDs == ["c", "d"])
        #expect(schedule["c"].map(\.programme.title) == ["Ten", "Eleven", "Twelve"])
        #expect(schedule["c"].map(\.index) == [1, 0, 2])
        #expect(schedule["c"].map(\.end) == [time(11), time(12), nil])
        #expect(schedule["c"][0].isEndInferred && !schedule["d"][0].isEndInferred)

        #expect(schedule.onAir("c", at: date(11, 30)).map(\.programme.title) == ["Eleven"])
        #expect(schedule.onAir("c", at: date(11)).map(\.programme.title) == ["Eleven"])
        #expect(schedule.next("c", after: date(11, 30))?.programme.title == "Twelve")
        // The last programme has no known end, so it is never on air.
        #expect(schedule.onAir("c", at: date(12, 30)).isEmpty)
        #expect(schedule.next("c", after: date(12)) == nil)
        // A gap.
        #expect(schedule.onAir("d", at: date(11)).isEmpty)
        #expect(schedule["missing"].isEmpty && schedule.onAir("missing", at: date(1)).isEmpty)
    }

    @Test func scheduleKeepsClumpsAndOverlaps() {
        var news = Programme(channelID: "c", start: time(10), title: "News")
        news.clump = .init(index: 0, count: 2)
        var weather = Programme(channelID: "c", start: time(10), title: "Weather")
        weather.clump = .init(index: 1, count: 2)
        let programmes = [
            Programme(channelID: "c", start: time(6), stop: time(23), title: "All day"),
            news, weather,
            Programme(channelID: "c", start: time(10, 30), stop: time(11), title: "Later"),
        ]
        let schedule = XMLTVSchedule(programmes: programmes)
        #expect(schedule["c"].map(\.end) == [time(23), time(10, 30), time(10, 30), time(11)])
        #expect(schedule.onAir("c", at: date(10, 15)).map(\.programme.title) == ["All day", "News", "Weather"])
        #expect(schedule.onAir("c", at: date(10, 45)).map(\.programme.title) == ["All day", "Later"])
        #expect(schedule.onAir("c", at: date(23)).isEmpty)
    }

    @Test func currentIsTheLatestStartedOfOverlappingProgrammes() {
        let schedule = XMLTVSchedule(programmes: [
            Programme(channelID: "c", start: time(10), stop: time(11, 5), title: "A"),
            Programme(channelID: "c", start: time(11), stop: time(12), title: "B"),
            Programme(channelID: "c", start: time(12), stop: time(13), title: "C"),
        ])
        #expect(schedule.onAir("c", at: date(11, 2)).map(\.programme.title) == ["A", "B"])
        #expect(schedule.current("c", at: date(11, 2))?.programme.title == "B")
        #expect(schedule.next("c", after: date(11, 2))?.programme.title == "C")
        #expect(schedule.current("c", at: date(13)) == nil)
    }

    @Test func scheduleIdentitySurvivesARefreshAndDuplicatesAreDropped() {
        var news = Programme(channelID: "c", start: time(10), title: "News")
        news.clump = .init(index: 0, count: 2)
        var weather = Programme(channelID: "c", start: time(10), title: "Weather")
        weather.clump = .init(index: 1, count: 2)
        let earlier = Programme(channelID: "c", start: time(9), stop: time(10), title: "Earlier")
        let later = Programme(channelID: "c", start: time(11), stop: time(12), title: "Later")

        let first = XMLTVSchedule(programmes: [earlier, news, weather, later, later])
        #expect(first["c"].map(\.programme.title) == ["Earlier", "News", "Weather", "Later"])
        #expect(first["c"].map(\.ordinal) == [0, 0, 1, 0])
        // A refresh without the earliest programme: every surviving entry keeps its ID.
        let refreshed = XMLTVSchedule(programmes: [later, news, weather])
        let ids = Dictionary(uniqueKeysWithValues: first["c"].map { ($0.programme.title!, $0.id) })
        for entry in refreshed["c"] { #expect(ids[entry.programme.title!] == entry.id) }
        #expect(first["c"][2].end == time(11) && first["c"][2].isEndInferred)
    }

    @Test func entryEqualityIgnoresTheDocumentPosition() throws {
        let show = Programme(channelID: "c", start: time(10), stop: time(11), title: "Show")
        let first = XMLTVSchedule(programmes: [show])["c"][0]
        let moved = XMLTVSchedule(programmes: [Programme(channelID: "d", start: time(1)), show])["c"][0]
        #expect(first.index != moved.index && first == moved && first.hashValue == moved.hashValue)
        let id = try JSONDecoder().decode(XMLTVSchedule.Entry.ID.self, from: JSONEncoder().encode(first.id))
        #expect(id == first.id)
    }

    @Test func largeGroupsThatStartTogetherStayFast() {
        let programmes = (0..<20_000).map { Programme(channelID: "c", start: time(10), title: "P\($0 % 10_000)") }
        let clock = ContinuousClock()
        var schedule: XMLTVSchedule?
        let elapsed = clock.measure { schedule = XMLTVSchedule(programmes: programmes) }
        #expect(schedule!["c"].count == 10_000)
        #expect(schedule!["c"].map(\.ordinal) == Array(0..<10_000))
        #expect(elapsed < .seconds(5))   // quadratic took about 10 s in release
    }

    @Test func scheduleListsDeclaredChannelsInOrderAndLooksThemUp() throws {
        let guide = try parse(document("""
        <channel id="b"><display-name>B</display-name></channel>
        <channel id="a"><display-name>A</display-name></channel>
        <channel id="a"><display-name>A again</display-name></channel>
        <channel id="empty"><display-name>No programmes</display-name></channel>
        <programme \(Self.start) channel="a"><title>t</title></programme>
        <programme \(Self.start) channel="undeclared"><title>t</title></programme>
        <programme \(Self.start) channel="b"><title>t</title></programme>
        """))
        let schedule = XMLTVSchedule(guide)
        #expect(schedule.channelIDs == ["b", "a", "empty", "undeclared"])
        #expect(schedule["empty"].isEmpty && schedule.current("empty", at: .now) == nil)
        #expect(schedule.channel("a")?.displayName == "A")
        #expect(schedule.channel("undeclared") == nil)
        #expect(XMLTVSchedule(programmes: guide.programmes).channelIDs == ["a", "undeclared", "b"])
    }

    @Test func scheduleMatchesALinearScanOnRealData() throws {
        let guide = try XMLTVDocument(contentsOf: Fixtures.url("upstream_test.xml"))
        let schedule = XMLTVSchedule(guide)
        let entries = schedule.channelIDs.flatMap { schedule[$0] }
        #expect(entries.count == guide.programmes.count)
        #expect(Set(entries.map(\.index)) == Set(guide.programmes.indices))
        #expect(Set(entries.map(\.id)).count == entries.count)
        let starts = entries.map(\.start.secondsSince1970)
        for channelID in schedule.channelIDs {
            for seconds in Set(starts) {
                for date in [Date(timeIntervalSince1970: TimeInterval(seconds)), Date(timeIntervalSince1970: TimeInterval(seconds + 59))] {
                    let expected = schedule[channelID].filter { $0.isOnAir(at: date) }
                    #expect(schedule.onAir(channelID, at: date) == expected)
                }
            }
        }
    }
}
