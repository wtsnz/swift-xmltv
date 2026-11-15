import Foundation
import Synchronization
import Testing
@testable import XMLTV

/// The conveniences and contracts added for app use: reports reachable after a loop, recovery
/// outcomes, readable errors, timestamps, schedules and lookups.
@Suite("App-facing API")
struct APITests {
    static let start = #"start="20240101120000 +0000""#

    func chunks(_ data: Data, size: Int) -> AsyncStream<Data> {
        AsyncStream { continuation in
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + size)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    // MARK: Streaming

    @Test func forAwaitLoopCanSeeATruncatedDownload() async throws {
        let gz = try Fixtures.data("upstream_test.xml.gz")
        let cut = gz.prefix(gz.count * 6 / 10)
        let items = XMLTVItems(chunks: chunks(Data(cut), size: 100))
        #expect(items.report == nil)
        var count = 0
        for try await _ in items { count += 1 }
        let report = try #require(items.report)
        #expect(report.isTruncated)
        #expect(report.inputByteCount == cut.count)
        #expect(report == (try XMLTVDocument(data: Data(cut))).report)
        #expect(items.info != nil)
    }

    @Test func documentFromChunksEqualsDocumentFromData() async throws {
        let data = try Fixtures.data("upstream_test.xml.gz")
        let whole = try XMLTVDocument(data: data)
        let streamed = try await XMLTVDocument(chunks: chunks(data, size: 7))
        #expect(streamed.channels == whole.channels)
        #expect(streamed.programmes == whole.programmes)
        #expect(streamed.report == whole.report)
        #expect(streamed.info == whole.info)
    }

    @Test func itemsFromSingleBytes() async throws {
        let data = try Fixtures.data("upstream_test.xml")
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
        let items = XMLTVItems(bytes: bytes, chunkSize: 100)
        var collected: [XMLTVItem] = []
        for try await item in items { collected.append(item) }
        #expect(collected == (try XMLTVDocument(data: data)).items)
        #expect(items.report?.inputByteCount == data.count)
    }

    @Test func readerMovesIntoATask() async throws {
        var reader = XMLTVReader(data: try Fixtures.data("upstream_test.xml"))
        _ = try reader.next()
        let remaining = try await Task.detached {
            var count = 0
            while try reader.next() != nil { count += 1 }
            return count
        }.value
        #expect(remaining > 0)
    }

    // MARK: Diagnostics

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

    @Test func errorsReadAsSentences() throws {
        do {
            _ = try parse("<tv><programme \(Self.start) channel=\"c\"><title>t</desc></programme></tv>")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "The guide is not well-formed XML: found </desc> where </title> was expected. (line 1, column 65)")
        }
        let missing = XMLTVError(.io(operation: "open", path: "/nope.xml", errno: ENOENT))
        #expect(missing.localizedDescription == "The file “/nope.xml” could not be read (open: No such file or directory).")
        let diagnostic = XMLTVDiagnostic(kind: .invalidTimestamp("2024x"), recovery: .programmeDropped, line: 12)
        #expect(diagnostic.message == "Line 12: The time “2024x” is not valid. The programme was skipped.")
        #expect(XMLTVError.Kind.invalidTimestamp("x").code == .invalidTimestamp)
        #expect(XMLTVError.Code.allCases.count == 18)
    }

    @Test func nonXMLAndRemoteURLsAreNamed() throws {
        for body in [#"{"error": "not found"}"#, "Service unavailable", "<!DOCTYPE html><html><body/></html>"] {
            #expect("\(body)") { try parse(body) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
        }
        let remote = URL(string: "https://example.com/guide.xml.gz")!
        #expect { try XMLTVDocument(contentsOf: remote) } throws: { ($0 as? XMLTVError)?.kind == .notAFileURL(remote.absoluteString) }
        #expect { _ = try XMLTVReader(contentsOf: remote) } throws: { ($0 as? XMLTVError)?.kind == .notAFileURL(remote.absoluteString) }
    }

    // MARK: Timestamps

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

    @Test func productionAndCreationDatesKeepPrecision() throws {
        let guide = try parse(#"<tv date="20240102"><programme \#(Self.start) channel="c"><title>t</title><date>1999</date></programme></tv>"#)
        #expect(guide.programmes[0].productionDate == XMLTVTimestamp(secondsSince1970: 915_148_800, precision: .year))
        #expect(guide.info.creationDate?.precision == .day)
    }

    // MARK: Model conveniences

    @Test func preferredLanguage() {
        let texts = [LocalizedText("Hello"), LocalizedText("Bonjour", language: "fr_FR"), LocalizedText("Hallo", language: "de"),
                     LocalizedText("G'day", language: "en-AU")]
        #expect(texts.preferred(for: ["de"])?.value == "Hallo")
        #expect(texts.preferred(for: ["fr-FR"])?.value == "Bonjour")
        #expect(texts.preferred(for: ["FR"])?.value == "Bonjour")
        #expect(texts.preferred(for: ["en-NZ", "de"])?.value == "G'day")
        #expect(texts.preferred(for: ["ja"])?.value == "Hello")
        #expect([LocalizedText]().preferred(for: ["en"]) == nil)
    }

    @Test func seasonAndEpisodeFromEitherSystem() {
        var programme = Programme(channelID: "c", start: XMLTVTimestamp(secondsSince1970: 0), title: "Show")
        programme.episodeNumbers = [.init("S03E10"), .init("2 . 9/22 . 0/2", system: "xmltv_ns")]
        #expect(programme.seasonEpisode == .init(season: 3, episode: 10, episodeCount: 22, part: 1, partCount: 2))
        programme.episodeNumbers = [.init("EP1", system: "dd_progid"), .init("S1 E5")]
        #expect(programme.seasonEpisode == .init(season: 1, episode: 5))
        programme.episodeNumbers = [.init(". . 0/1", system: "xmltv_ns")]
        #expect(programme.seasonEpisode == nil)
        #expect(programme.title == "Show")
    }

    @Test func creditsByRoleAndChannelLookup() throws {
        let guide = try parse(document("""
        <channel id="a"><display-name>First</display-name></channel>
        <channel id="a"><display-name>Second</display-name></channel>
        <programme \(Self.start) channel="a"><title>t</title><credits><director>D</director><actor>A1</actor><actor>A2</actor></credits></programme>
        """))
        #expect(guide.channel(id: "a")?.displayName == "First")
        #expect(guide.channel(id: "b") == nil)
        #expect(guide.programmes[0].credits(.actor).map(\.name) == ["A1", "A2"])
        #expect(Programme.Credit.Role(rawValue: "commentator") == .commentator)
    }

    @Test func optionsAreHashableAndHaveAMemberwiseInitializer() {
        var built = XMLTVOptions()
        built.channelIDs = ["a"]
        built.policy = .strict
        #expect(XMLTVOptions(policy: .strict, channelIDs: ["a"]) == built)
        #expect(Set([built, XMLTVOptions(policy: .strict, channelIDs: ["a"])]).count == 1)
    }

    // MARK: Schedule

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

    // MARK: Second review

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

    @Test func damagedGzipIsRecoveredWhateverTheChunking() async throws {
        var gz = Array(try Fixtures.data("upstream_test.xml.gz"))
        gz[gz.count - 6] ^= 0xFF   // the CRC in the trailer
        let whole = try XMLTVDocument(data: Data(gz))
        #expect(whole.report.diagnosticCountsByCode[.invalidCompressedData] == 1 && !whole.programmes.isEmpty)
        for chunkSize in [1, 100, gz.count] {
            let streamed = try streamDecode(gz, chunkSize: chunkSize)
            #expect(streamed.report == whole.report, "chunk \(chunkSize)")
        }
        var reader = XMLTVReader(data: Data(gz))
        while try reader.next() != nil {}
        #expect(reader.report == whole.report)
        #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(gz), options: XMLTVOptions(policy: .strict)) }
    }

    @Test func iteratorCopiesShareOneCursor() async throws {
        let data = Data(document(#"<channel id="a"><display-name>A</display-name></channel><channel id="b"><display-name>B</display-name></channel>"#).utf8)
        // A source whose iterator is a value, so copying it copies its position.
        struct Replayable: AsyncSequence {
            let chunks: [Data]
            struct AsyncIterator: AsyncIteratorProtocol {
                let chunks: [Data]
                var index = 0
                mutating func next() async -> Data? {
                    defer { index += 1 }
                    return index < chunks.count ? chunks[index] : nil
                }
            }
            func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks) }
        }
        let chunks = stride(from: 0, to: data.count, by: 40).map { data.subdata(in: $0..<min(data.count, $0 + 40)) }
        var first = XMLTVItems(chunks: Replayable(chunks: chunks)).makeAsyncIterator()
        var second = first
        let a = try await first.next()
        let b = try await second.next()
        #expect(a == .channel(Channel(id: "a", displayNames: [LocalizedText("A")])))
        #expect(b == .channel(Channel(id: "b", displayNames: [LocalizedText("B")])))
        #expect(try await first.next() == nil)
        #expect(!first.report.isTruncated)
    }

    @Test func reportIsStableAfterTheEnd() throws {
        var reader = XMLTVReader(data: Data("<tv><programme/>".utf8))
        while try reader.next() != nil {}
        let report = reader.report
        #expect(try reader.next() == nil)
        #expect(reader.report == report)
    }

    @Test func reportIsPublishedWhenTheLoopEndsEarly() async throws {
        let data = try Fixtures.data("upstream_test.xml")
        let items = XMLTVItems(chunks: chunks(data, size: 50))
        for try await _ in items { break }
        let report = try #require(items.report)
        #expect(!report.isTruncated && report.inputByteCount > 0)
        #expect(items.info != nil)
    }

    @MainActor @Test func bytesFromTheMainActor() async throws {
        let data = try Fixtures.data("upstream_test.xml")
        let bytes = ProbeBytes(data: Array(data))
        var count = 0
        for try await _ in XMLTVItems(bytes: bytes, chunkSize: 64) { count += 1 }
        #expect(count == (try XMLTVDocument(data: data)).items.count)
        // The byte loop runs off the main actor: no byte is read on the main thread. Reading
        // bytes on the caller's actor made this path 125 times slower from the main actor.
        #expect(bytes.counter.mainThreadCalls.load(ordering: .relaxed) == 0)
        #expect(bytes.counter.calls.load(ordering: .relaxed) > data.count)

        // The probe does see main-thread reads: iterating it directly here makes them. (On Apple
        // platforms only: elsewhere the main actor need not run on the main thread.)
        #if canImport(Darwin)
        let direct = ProbeBytes(data: [1, 2, 3])
        for await _ in direct {}
        #expect(direct.counter.mainThreadCalls.load(ordering: .relaxed) > 0)
        #endif
    }

    @Test func bytesGatheredBeforeASourceErrorAreParsed() async throws {
        struct Dropped: Error {}
        let data = Array(try Fixtures.data("upstream_test.xml"))
        let cut = data.count * 3 / 4
        let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in data[..<cut] { continuation.yield(byte) }
            continuation.finish(throwing: Dropped())
        }
        let items = XMLTVItems(bytes: bytes, chunkSize: 1 << 20)
        var count = 0
        await #expect(throws: Dropped.self) {
            for try await _ in items { count += 1 }
        }
        #expect(count > 0)
        #expect(items.report?.inputByteCount == cut)
    }

    @Test func onlyStartedIterationsPublishAndOnlyOnce() async throws {
        let data = try Fixtures.data("upstream_test.xml.gz")
        let cut = Data(data.prefix(data.count / 2))
        let items = XMLTVItems(chunks: ReplayableChunks(stride(from: 0, to: cut.count, by: 64).map {
            cut.subdata(in: $0..<min(cut.count, $0 + 64))
        }))
        var older = items.makeAsyncIterator()
        while try await older.next() != nil {}
        #expect(items.report?.isTruncated == true)
        _ = items.makeAsyncIterator()   // made and dropped, never advanced
        #expect(items.report?.isTruncated == true)
        for try await _ in items { break }   // a newer iteration, abandoned
        #expect(items.report?.isTruncated == false)
        _ = try await older.next()          // the older one again: already published
        withExtendedLifetime(older) {}
        #expect(items.report?.isTruncated == false)
    }

    @Test func compressionProblemsComeBeforeEncodingProblemsOnEveryPath() throws {
        var utf16 = Array("\u{FEFF}<tv><channel id=\"c\"><display-name>".utf16)
        utf16.append(0xD800)
        utf16 += Array("</display-name></channel></tv>".utf16)
        let xml = Data(utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID()).xml")
        try xml.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        var gz = Array(try Data(contentsOf: URL(fileURLWithPath: url.path + ".gz")))
        try? FileManager.default.removeItem(atPath: url.path + ".gz")
        gz[gz.count - 6] ^= 0xFF   // the CRC
        let document = try XMLTVDocument(data: Data(gz)).report
        #expect(document.diagnostics.map(\.code) == [.invalidCompressedData, .invalidEncoding])
        for chunkSize in [1, 7, gz.count] {
            #expect(try streamDecode(gz, chunkSize: chunkSize).report == document, "chunk \(chunkSize)")
        }
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

    @Test func textWithBothProblemsReportsBoth() throws {
        let bytes = Array("<tv><programme start=\"2024\" channel=\"c\"><title>a".utf8) + [0x00, 0xFF] + Array("</title></programme></tv>".utf8)
        let report = try XMLTVDocument(data: Data(bytes)).report
        #expect(report.diagnostics.map(\.kind) == [.invalidCharacter(0), .invalidUTF8])
        #expect(report.diagnostics.map(\.recovery) == [.keptAsWritten, .repaired])
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

    @Test func timestampJSONLeavesOutDefaults() throws {
        let plain = XMLTVTimestamp(secondsSince1970: 1_704_110_400)
        #expect(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self) == #"{"secondsSince1970":1704110400}"#)
        #expect(try JSONDecoder().decode(XMLTVTimestamp.self, from: Data(#"{"secondsSince1970":1704110400}"#.utf8)) == plain)
    }

    @Test func smallerFixes() throws {
        #expect(Programme.EpisodeNumber("S3").onscreen == .init(season: 3))
        let texts = [LocalizedText("Hallo", language: "de"), LocalizedText("Hello")]
        #expect(texts.preferred(for: ["fr"])?.value == "Hello")
        #expect(XMLTVDiagnostic(kind: .invalidUTF8, recovery: .repaired).message == "Some text is not valid UTF-8. It was repaired.")
        #expect(XMLTVError(.notXMLTV, line: 1, column: 1).localizedDescription == "This is not an XMLTV guide.")
        #expect(XMLTVError(.invalidUTF8).code == .invalidUTF8)
        // A truncated gzip stream reports the cause before its effect.
        let gz = try Fixtures.data("upstream_test.xml.gz")
        let report = try XMLTVDocument(data: gz.prefix(gz.count / 2)).report
        #expect(report.diagnostics.suffix(2).map(\.code) == [.invalidCompressedData, .unexpectedEndOfInput])
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
        #expect(schedule.channelIDs == ["b", "a", "undeclared"])
        #expect(schedule.channel("a")?.displayName == "A")
        #expect(schedule.channel("undeclared") == nil)
        #expect(XMLTVSchedule(programmes: guide.programmes).channelIDs == ["a", "undeclared", "b"])
    }
}

/// A sendable byte sequence that counts how often it is read on the main thread.
struct ProbeBytes: AsyncSequence, Sendable {
    final class Counter: Sendable {
        let calls = Atomic<Int>(0)
        let mainThreadCalls = Atomic<Int>(0)
    }

    let data: [UInt8]
    let counter = Counter()

    struct AsyncIterator: AsyncIteratorProtocol {
        let data: [UInt8]
        let counter: Counter
        var index = 0

        mutating func next() async -> UInt8? { advance() }

        /// Runs on the caller's actor, as a source with isolated reads does.
        mutating func next(isolation actor: isolated (any Actor)?) async -> UInt8? { advance() }

        private mutating func advance() -> UInt8? {
            counter.calls.add(1, ordering: .relaxed)
            if Thread.isMainThread { counter.mainThreadCalls.add(1, ordering: .relaxed) }
            defer { index += 1 }
            return index < data.count ? data[index] : nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(data: data, counter: counter) }
}

/// Chunks that can be iterated more than once, each iteration from the start.
struct ReplayableChunks: AsyncSequence, Sendable {
    let chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [Data]
        var index = 0
        mutating func next() async -> Data? {
            defer { index += 1 }
            return index < chunks.count ? chunks[index] : nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks) }
}
