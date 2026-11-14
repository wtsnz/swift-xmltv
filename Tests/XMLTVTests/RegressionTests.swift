import Foundation
import Testing
@testable import XMLTV

/// One test per defect found by the council's implementation review (research/review-opus.md
/// and research/review-sol.md). Each asserts the corrected behaviour.
@Suite("Review regressions")
struct RegressionTests {
    static let attributes = #"start="20240101120000 +0000" channel="c""#
    static let strict = ParseOptions.with { $0.policy = .strict }

    func offset(of needle: String, in text: String) -> Int {
        let haystack = Array(text.utf8), pattern = Array(needle.utf8)
        return (0...(haystack.count - pattern.count)).first { Array(haystack[$0..<($0 + pattern.count)]) == pattern }!
    }

    func gzip(_ text: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID()).xml")
        try Data(text.utf8).write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: url.path + ".gz") }
        return try Data(contentsOf: URL(fileURLWithPath: url.path + ".gz"))
    }

    // MARK: Streaming completion and retries

    @Test(arguments: [1, 5, 7, 13])
    func retryInsideTheEpilogKeepsThePhase(chunkSize: Int) throws {
        let xml = "<tv><programme \(Self.attributes)><title>t</title></programme></tv>\n<!-- a trailing comment -->\n"
        let streamed = try streamDecode(Array(xml.utf8), chunkSize: chunkSize)
        #expect(streamed.report == (try parse(xml)).report)
        #expect(throws: Never.self) { try streamDecode(Array(xml.utf8), chunkSize: chunkSize, options: Self.strict) }
    }

    @Test func streamReadsToTheEndBeforeFinishing() throws {
        let head = "<tv><programme \(Self.attributes)><title>t</title></programme></tv>"
        let xml = head + "<junk/>"
        #expect(throws: XMLTVError.self) { try parse(xml, options: Self.strict) }
        #expect(throws: XMLTVError.self) { try streamDecode(Array(xml.utf8), chunkSize: head.utf8.count, options: Self.strict) }
        let lenient = try streamDecode(Array(xml.utf8), chunkSize: head.utf8.count)
        #expect(lenient.report.diagnostics.map(\.kind) == [.contentAfterRoot])
    }

    @Test func streamValidatesTheGzipTrailerAndTheLastUTF16Unit() throws {
        let gz = Array(try gzip("<tv></tv>"))
        let cut = Array(gz.dropLast(4))
        #expect(throws: XMLTVError.self) { try streamDecode(cut, chunkSize: 4, options: Self.strict) }
        #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(cut), options: Self.strict) }
        #expect(try streamDecode(cut, chunkSize: 4).report == (try XMLTVDocument(data: Data(cut))).report)

        var utf16 = Array("\u{FEFF}<tv><programme start=\"2024\" channel=\"c\"><title>".utf16)
        utf16.append(0xD800)
        utf16 += Array("</title></programme></tv>".utf16)
        let bytes = utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(throws: XMLTVError.self) { try streamDecode(bytes, chunkSize: 1 << 20, options: Self.strict) }
        #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(bytes), options: Self.strict) }
        #expect(try streamDecode(bytes, chunkSize: 7).report == (try XMLTVDocument(data: Data(bytes))).report)
    }

    @Test(arguments: [1, 2, 3, 5, 64])
    func gzipMemberMagicSplitAcrossChunks(chunkSize: Int) throws {
        let bytes = Array(try Fixtures.data("split_members.xml.gz"))
        let whole = try XMLTVDocument(data: Data(bytes))
        let streamed = try streamDecode(bytes, chunkSize: chunkSize)
        #expect(sortedByKind(streamed.items) == whole.items)
        #expect(streamed.report == whole.report)
    }

    @Test func truncatedGzipKeepsCompleteRecords() throws {
        var xml = "<tv>\n"
        for i in 0..<2000 { xml += "<programme \(Self.attributes)><title>Show \(i)</title></programme>\n" }
        xml += "</tv>\n"
        let gz = try gzip(xml)
        let cut = Data(gz.prefix(gz.count / 2))
        let guide = try XMLTVDocument(data: cut)
        #expect(guide.report.isTruncated && guide.programmes.count > 500)
        #expect(guide.programmes.map(\.title) == (0..<guide.programmes.count).map { "Show \($0)" })
        #expect(try streamDecode(Array(cut), chunkSize: 4096).report == guide.report)
    }

    // MARK: Diagnostics are independent of how the input is split

    @Test func cachesNeverHideDiagnostics() throws {
        let bad = Array("Twenty byte title ".utf8) + [0xFF]
        func programme(_ extra: String = "") -> [UInt8] {
            Array("<programme start=\"2024\" channel=\"c&bogus;\"><title>".utf8) + bad + Array("</title>\(extra)</programme>\n".utf8)
        }
        let first = Array("<tv>\n".utf8) + programme("<desc>a fairly long description</desc>")
        let bytes = first + programme() + Array("</tv>\n".utf8)
        let serial = try parse(bytes, splits: [])
        #expect(serial.report.diagnosticCount == 4)
        #expect(try parse(bytes, splits: [first.count]).report == serial.report)
        for chunkSize in [1, 3, 8, 40] {
            #expect(try streamDecode(bytes, chunkSize: chunkSize).report.diagnosticCount == 4, "chunk \(chunkSize)")
        }
    }

    @Test func speculativePrefixDoesNotUseUpTheSamples() throws {
        var xml = "<tv>\n<programme \(Self.attributes)><title>real</title></programme>\n<!--\n"
        for _ in 0..<120 { xml += #"<programme start="bogus" channel="g"><title>g</title></programme>"# + "\n" }
        xml += "-->\n<programme start=\"also bogus\" channel=\"c\"><title>x</title></programme>\n</tv>\n"
        let bytes = Array(xml.utf8)
        let serial = try parse(bytes, splits: [])
        #expect(serial.report.diagnostics.count == 1)
        #expect(try parse(bytes, splits: [offset(of: "<programme start=\"bogus\"", in: xml)]).report == serial.report)
    }

    @Test func diagnosticsAreInDocumentOrderWithTheirOwnLines() throws {
        let xml = "<tv>\n<programme \(Self.attributes)>\n<desc>x &bogus;</desc>\n</programme>\n<channel id=\"c\">\n<icon/>\n</channel>\n</tv>\n"
        let report = try parse(xml).report
        #expect(report.diagnostics.map(\.line) == [2, 3, 5, 6])
        #expect(report.diagnostics.map(\.byteOffset) == report.diagnostics.map(\.byteOffset).sorted())
        #expect(try streamDecode(Array(xml.utf8), chunkSize: 1 << 20).report == report)
        #expect(try streamDecode(Array(xml.utf8), chunkSize: 3).report == report)
    }

    // MARK: Well-formedness everywhere

    @Test func skippedContentIsStillChecked() {
        let filtered = ParseOptions.with { $0.channelIDs = ["other"] }
        for xml in [
            "<tv><x><a></b></x></tv>",
            "<tv><x><a bad=unquoted></a></x></tv>",
            "<tv><programme \(Self.attributes)><title>t</desc></programme></tv>",
        ] {
            #expect(throws: XMLTVError.self, "\(xml)") { try parse(xml) }
            #expect(throws: XMLTVError.self, "\(xml)") { try parse(xml, options: filtered) }
        }
    }

    @Test func forbiddenCharactersAndRawLessThan() throws {
        for scalar in ["\u{0}", "\u{1}", "\u{FFFE}"] {
            let xml = document(programme("<title>a\(scalar)b</title>"))
            #expect(throws: XMLTVError.self) { try parse(xml, options: Self.strict) }
            #expect(try parse(xml).report.diagnosticCount == 1)
        }
        #expect(throws: XMLTVError.self) { try parse(#"<tv><channel id="a<b"><display-name>N</display-name></channel></tv>"#) }
    }

    @Test func doctypeCommentMayContainQuotes() throws {
        let xml = "<?xml version=\"1.0\"?>\n<!DOCTYPE tv [\n<!-- it's a comment -->\n<!ELEMENT tv ANY>\n]>\n<tv><programme \(Self.attributes)><title>t</title></programme></tv>\n"
        #expect(try parse(xml).programmes.count == 1)
    }

    // MARK: Values

    @Test func hugeValuesNeverTrap() throws {
        let length = try parse(document(programme(#"<title>t</title><length units="hours">1e308</length>"#)))
        #expect(length.programmes[0].length == nil && length.report.diagnosticCount == 1)
        let episode = try parse(document(programme(#"<title>t</title><episode-num system="xmltv_ns">9223372036854775807.0.</episode-num>"#)))
        #expect(episode.programmes[0].episodeNumbers[0].xmltvNS?.displaySeason == nil)
        #expect(XMLTVNS("-1.0.0") == nil)
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

    @Test func encodingOverrideIgnoresTheDeclaration() throws {
        let xml = #"<?xml version="1.0" encoding="bogus"?><tv><programme start="2024" channel="c"><title>é</title></programme></tv>"#
        #expect(throws: XMLTVError.self) { try parse(xml) }
        let guide = try parse(xml, options: .with { $0.encoding = .utf8 })
        #expect(guide.programmes[0].title == "é")
        var reader = XMLTVReader(data: Data(xml.utf8), options: .with { $0.encoding = .utf8 })
        #expect(try reader.next() != nil)
    }

    @Test func manyAttributesAreAccepted() throws {
        let extra = (0..<100).map { "x\($0)=\"\($0)\"" }.joined(separator: " ")
        let guide = try parse(document("<programme \(Self.attributes) \(extra)><title>t</title></programme>"))
        #expect(guide.programmes.count == 1)
    }

    @Test func threadCountIsHonouredWithoutChangingTheResult() throws {
        let data = Data(ParallelTests.adversarial)
        let serial = try XMLTVDocument(data: data, options: .with { $0.parallelism = .serial })
        for threads in [1, 2, 3] {
            let parallel = try XMLTVDocument(data: data, options: .with { $0.parallelism = .threads(threads) })
            #expect(parallel.programmes == serial.programmes && parallel.report == serial.report)
        }
    }
}
