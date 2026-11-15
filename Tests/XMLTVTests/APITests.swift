import Foundation
import Synchronization
import Testing
@testable import XMLTV

/// The conveniences and contracts added for app use: readable errors, lookups, options, and
/// the encoded forms of values apps store.
@Suite("App-facing API")
struct APITests {
    static let start = #"start="20240101120000 +0000""#

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
        #expect(XMLTVError.Code.allCases.count == 19)
        #expect(XMLTVError(.recordTooLarge(maximumSize: 16 << 20)).localizedDescription == "The guide has a record larger than the 16 MiB that a streaming read allows.")
    }

    @Test func nonXMLAndRemoteURLsAreNamed() throws {
        for body in [#"{"error": "not found"}"#, "Service unavailable", "<!DOCTYPE html><html><body/></html>"] {
            #expect("\(body)") { try parse(body) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
        }
        let remote = URL(string: "https://example.com/guide.xml.gz")!
        #expect { try XMLTVDocument(contentsOf: remote) } throws: { ($0 as? XMLTVError)?.kind == .notAFileURL(remote.absoluteString) }
        #expect { _ = try XMLTVReader(contentsOf: remote) } throws: { ($0 as? XMLTVError)?.kind == .notAFileURL(remote.absoluteString) }
    }

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

    @Test func shortFormsMessagesAndCodes() {
        #expect(Programme.EpisodeNumber("S3").onscreen == .init(season: 3))
        let texts = [LocalizedText("Hallo", language: "de"), LocalizedText("Hello")]
        #expect(texts.preferred(for: ["fr"])?.value == "Hello")
        #expect(XMLTVDiagnostic(kind: .invalidUTF8, recovery: .repaired).message == "Some text is not valid UTF-8. It was repaired.")
        #expect(XMLTVError(.notXMLTV, line: 1, column: 1).localizedDescription == "This is not an XMLTV guide.")
        #expect(XMLTVError(.invalidUTF8).code == .invalidUTF8)
        #expect(XMLTVError(.invalidValue(element: "length", attribute: nil, value: "")).localizedDescription == "A <length> is empty.")
        #expect(XMLTVError(.invalidValue(element: "programme", attribute: "clumpidx", value: "x")).localizedDescription
            == "A <programme> has a “clumpidx” attribute that could not be read: “x”.")
    }

    /// A refresh that changed nothing gives an equal document; any change gives a different one.
    @Test func documentsCompareByContent() throws {
        let data = try Fixtures.data("upstream_test.xml")
        let first = try XMLTVDocument(data: data), second = try XMLTVDocument(data: data)
        #expect(first == second && first.hashValue == second.hashValue)
        var changed = second
        changed.programmes[0].titles[0].value += "!"
        #expect(first != changed)
        // The report describes the transport, not the guide.
        let gzipped = try XMLTVDocument(data: try Fixtures.data("upstream_test.xml.gz"))
        #expect(gzipped.report != first.report && gzipped == first && gzipped.hashValue == first.hashValue)
    }

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
        try roundTrips(Programme.EpisodeNumber("1.4.", system: "xmltv_ns"), as: #"{"system":"xmltv_ns","value":"1.4."}"#)
        try roundTrips(Programme.SeasonEpisode(season: 2, episode: 5), as: #"{"episode":5,"season":2}"#)
        try roundTrips(Programme.Rating("PG", system: "MPAA"), as: #"{"icons":[],"system":"MPAA","value":"PG"}"#)
        try roundTrips(Programme.StarRating("3/5"), as: #"{"icons":[],"value":"3\/5"}"#)
        try roundTrips(Programme.Clump(index: 1, count: 2), as: #"{"count":2,"index":1}"#)
        try roundTrips(Programme.Credit.Role.presenter, as: #""presenter""#)
        try roundTrips(XMLTVEncoding.windows1252, as: #""windows-1252""#)
    }
}

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

/// Chunks that record whether they were read on the main thread.
struct ProbeChunks: AsyncSequence, Sendable {
    let chunks: [Data]
    let mainThreadCalls = ProbeBytes.Counter()

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [Data]
        let counter: ProbeBytes.Counter
        var index = 0

        mutating func next() async -> Data? { advance() }
        mutating func next(isolation actor: isolated (any Actor)?) async -> Data? { advance() }

        private mutating func advance() -> Data? {
            counter.calls.add(1, ordering: .relaxed)
            if Thread.isMainThread { counter.mainThreadCalls.add(1, ordering: .relaxed) }
            defer { index += 1 }
            return index < chunks.count ? chunks[index] : nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks, counter: mainThreadCalls) }
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
