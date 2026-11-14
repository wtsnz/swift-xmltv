import Foundation
import Testing
import XMLTV

/// The code examples from README.md and the DocC articles, compiled and run, so the
/// documentation cannot drift from the API. Each test names the article it comes from.
@Suite("Documentation examples")
struct DocumentationExamplesTests {
    let url = Fixtures.url("upstream_test.xml")

    @Test func gettingStarted() throws {
        let guide = try XMLTVDocument(contentsOf: url)
        _ = guide.info.generatorInfoName ?? "unknown generator"

        let now = Date.now
        let onNow = guide.programmes.filter { programme in
            programme.start.date <= now && (programme.stop?.date ?? .distantFuture) > now
        }
        for programme in onNow {
            let episode = programme.episodeNumbers.lazy.compactMap(\.xmltvNS).first
            _ = (programme.channelID, programme.title ?? "", episode?.displaySeason ?? 0, episode?.displayEpisode ?? 0)
        }

        var options = ParseOptions()
        options.channelIDs = ["BBC.One.uk", "ITV1.uk"]
        options.timeWindow = Date.now ..< Date.now.addingTimeInterval(24 * 3600)
        let tonight = try XMLTVDocument(contentsOf: url, options: options)
        #expect(tonight.programmes.isEmpty)

        if guide.report.isTruncated { Issue.record("fixture is complete") }
        for diagnostic in guide.report.diagnostics { _ = "\(diagnostic)" }
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

        let downloadChunks = AsyncStream<Data> { continuation in
            continuation.yield(try! Data(contentsOf: url))
            continuation.finish()
        }
        var items = XMLTVItems(chunks: downloadChunks).makeAsyncIterator()
        var streamed: [XMLTVItem] = []
        while let item = try await items.next() { streamed.append(item) }
        #expect(!items.report.isTruncated)
        #expect(streamed == stored)
    }

    @Test func timestamps() throws {
        var options = ParseOptions()
        options.namedTimeZones["IST"] = 19_800
        options.namedTimeZones["CET"] = 3_600
        _ = try XMLTVDocument(contentsOf: url, options: options)
    }

    @Test func errorsAndDiagnostics() {
        var options = ParseOptions()
        options.policy = .strict
        #expect(throws: XMLTVError.self) {
            _ = try XMLTVDocument(data: Data("<tv><programme start=\"x\" channel=\"c\"/></tv>".utf8), options: options)
        }
    }

    @Test func formatSupport() throws {
        var options = ParseOptions()
        options.encoding = .windows1252
        _ = try XMLTVDocument(contentsOf: url, options: options)
    }
}
