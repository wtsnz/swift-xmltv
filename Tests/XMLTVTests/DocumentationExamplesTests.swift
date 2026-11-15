import Foundation
import Testing
import XMLTV

/// The code examples from README.md and the DocC articles, compiled and run, so the
/// documentation cannot drift from the API. Each test names the article it comes from. Examples
/// that need the network are compiled but given a file URL.
@Suite("Documentation examples")
struct DocumentationExamplesTests {
    let url = Fixtures.url("upstream_test.xml")

    @Test func landingPageAndReadme() throws {
        let guide = try XMLTVDocument(contentsOf: url)
        let schedule = XMLTVSchedule(guide)
        if let now = schedule.current("BBC.One.uk", at: .now) {
            _ = (now.programme.title ?? "", "until", now.end?.date.formatted() ?? "unknown")
        }
        for channelID in schedule.channelIDs {
            let now = schedule.current(channelID, at: .now)
            let next = schedule.next(channelID, after: .now)
            _ = (schedule.channel(channelID)?.displayName ?? channelID, now?.programme.title ?? "-", next?.programme.title ?? "-")
        }
        let mine = try XMLTVDocument(contentsOf: url, options: XMLTVOptions(channelIDs: ["BBC.One.uk", "ITV1.uk"]))
        #expect(mine.programmes.isEmpty)
    }

    @Test func gettingStarted() throws {
        let guide = try XMLTVDocument(contentsOf: url)
        _ = guide.info.generatorInfoName ?? "unknown generator"

        let schedule = XMLTVSchedule(guide)
        let now = Date.now
        for channelID in schedule.channelIDs {
            let name = schedule.channel(channelID)?.displayName ?? channelID
            let onNow = schedule.current(channelID, at: now)
            let upNext = schedule.next(channelID, after: now)
            _ = (name, onNow?.programme.title ?? "-", "then", upNext?.programme.title ?? "-")
        }

        var printed = 0
        for entry in schedule[schedule.channelIDs[0]].prefix(5) {
            let programme = entry.programme
            let title = programme.titles.preferred()?.value ?? "Untitled"
            let episode = programme.seasonEpisode.map { "S\($0.season ?? 0)E\($0.episode ?? 0)" } ?? ""
            let cast = programme.credits(.actor).prefix(3).map(\.name)
            let poster = programme.images.first?.url ?? programme.icons.first?.url
            _ = (entry.start, title, episode, cast, poster?.absoluteString ?? "")
            printed += 1
        }
        #expect(printed > 0)

        let options = XMLTVOptions(
            channelIDs: ["BBC.One.uk", "ITV1.uk"],
            timeWindow: .now ..< .now.addingTimeInterval(24 * 3600))
        let tonight = try XMLTVDocument(contentsOf: url, options: options)
        #expect(tonight.programmes.isEmpty)

        let report = guide.report
        if report.isTruncated { Issue.record("fixture is complete") }
        if report.droppedProgrammeCount > 0 { Issue.record("fixture is clean") }
        for diagnostic in report.diagnostics.prefix(10) { _ = diagnostic.message }
    }

    @Test func choosingAnEntryPoint() async throws {
        var stored: [XMLTVItem] = []
        var reader = try XMLTVReader(contentsOf: url)
        while let item = try reader.next() {
            switch item {
            case .channel(let channel): stored.append(.channel(channel))
            case .programme(let programme): stored.append(.programme(programme))
            }
        }
        #expect(reader.report.diagnosticCount == 0)

        // "Guides from the network", with a file URL standing in for the server.
        // `URLSession.AsyncBytes` exists only on Apple platforms.
        #if canImport(Darwin)
        let guideURL = url
        let (bytes, _) = try await URLSession.shared.bytes(from: guideURL)
        let items = XMLTVItems(bytes: bytes)
        var streamed: [XMLTVItem] = []
        for try await item in items { streamed.append(item) }
        let report = try #require(items.report)
        #expect(!report.isTruncated)
        #expect(streamed == stored)
        #endif

        let guide = try await GuideModel.load(url)
        #expect(guide.programmes.count == stored.count - guide.channels.count)

        var reader2 = try XMLTVReader(contentsOf: url)
        let count = try await Task.detached {
            var count = 0
            while try reader2.next() != nil { count += 1 }
            return count
        }.value
        #expect(count == stored.count)

        let importer = Importer(reader: try XMLTVReader(contentsOf: url))
        #expect(try await importer.importNext() != nil)
        let chunks = AsyncStream<Data> { continuation in
            continuation.yield(try! Data(contentsOf: url))
            continuation.finish()
        }
        let imported = try await importer.importAll(XMLTVItems(chunks: chunks))
        #expect(imported.diagnosticCount == 0)
    }

    #if canImport(Darwin)
    /// Compiled, not run: it needs a server.
    func downloadThenParse(_ guideURL: URL) async throws -> XMLTVDocument {
        struct BadStatus: Error {}
        let (file, response) = try await URLSession.shared.download(from: guideURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BadStatus() }
        return try XMLTVDocument(contentsOf: file)
    }
    #endif

    @Test func timestamps() throws {
        var options = XMLTVOptions()
        options.namedTimeZones["IST"] = 19_800
        options.namedTimeZones["CET"] = 3_600
        let guide = try XMLTVDocument(contentsOf: url, options: options)

        let programme = guide.programmes[0]
        _ = programme.start.date.formatted(date: .omitted, time: .shortened)
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = programme.start.timeZone ?? .gmt
        _ = programme.start.date.formatted(style)
        if let made = programme.productionDate {
            _ = "Made in \(made)"
        }
        // The article's point: a year is shown as the year, in any zone.
        var year = Programme(channelID: "c", start: XMLTVTimestamp(secondsSince1970: 0))
        year.date = "2024"
        #expect("\(year.productionDate!)" == "2024")

        let start = try XMLTVTimestamp("20240101203000 +0100", policy: .strict)
        let lenient = try XMLTVTimestamp("20261113006000", policy: .lenient)
        #expect(start.description == "2024-01-01T20:30:00+01:00")
        #expect(lenient.description == "2026-11-13T01:00:00Z")
    }

    @Test func errorsAndDiagnostics() throws {
        let guide = try XMLTVDocument(contentsOf: url)
        let report = guide.report
        var problems: [String] = []
        if report.isTruncated { problems.append("The guide was cut off.") }
        if report.droppedProgrammeCount > 0 { problems.append("\(report.droppedProgrammeCount) programmes could not be read.") }
        var logged: [String] = []
        for (code, count) in report.diagnosticCountsByCode.sorted(by: { $0.value > $1.value }) {
            logged.append("\(code.rawValue): \(count)")
        }
        #expect(problems.isEmpty && logged.isEmpty)

        #expect(throws: XMLTVError.self) {
            _ = try XMLTVDocument(data: Data("<tv><programme start=\"x\" channel=\"c\"/></tv>".utf8), options: XMLTVOptions(policy: .strict))
        }
    }

    @Test func formatSupport() throws {
        var options = XMLTVOptions()
        options.encoding = .windows1252
        _ = try XMLTVDocument(contentsOf: url, options: options)
    }
}

// From "Choosing an entry point", Concurrency.

@concurrent
func loadGuide(from file: URL) async throws -> XMLTVDocument {
    try XMLTVDocument(contentsOf: file)
}

@MainActor
final class GuideModel {
    var guide: XMLTVDocument?

    func refresh(from file: URL) async throws {
        guide = try await loadGuide(from: file)
    }

    static func load(_ file: URL) async throws -> XMLTVDocument {
        let model = GuideModel()
        try await model.refresh(from: file)
        return model.guide!
    }
}

actor Importer {
    private var reader: XMLTVReader

    init(reader: consuming XMLTVReader) {
        self.reader = reader
    }

    func importNext() throws -> XMLTVItem? {
        try reader.next()
    }
}

extension Importer {
    func importAll<Chunks>(_ items: XMLTVItems<Chunks>) async throws -> XMLTVReport {
        var iterator = items.makeAsyncIterator()
        while let item = try await iterator.next() {
            _ = item   // store it
        }
        return iterator.report
    }
}
