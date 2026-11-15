import Foundation
import Testing
@testable import XMLTV

/// Diagnostics come in document order with their own lines and columns, however the input is split or chunked.
@Suite("Diagnostic order and location")
struct DiagnosticLocationTests {
    static let attributes = #"start="20240101120000 +0000" channel="c""#
    static let strict = XMLTVOptions(policy: .strict)

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

    @Test func carriageReturnsEndLines() throws {
        let xml = "<tv>\r<programme channel=\"c\"/>\r\n<programme channel=\"c\"/>\r</tv>"
        let report = try expectSamePaths(xml).report
        #expect(report.diagnostics.map(\.line) == [2, 3])
    }

    /// A chunk boundary inside a CR LF pair must not count the pair twice. Every chunk size
    /// from 1 to 12 puts a boundary inside one of these pairs.
    @Test func crlfSplitByAChunkCountsOnce() throws {
        let documents = [
            "<tv></tv>\r\n\r\n\r\ngarbage",
            "<tv>\r\n" + programme("<title>t</title>", attributes: #"start="bad" channel="c""#) + "\r\n</tv>\r\n\r\n<x/>",
        ]
        for xml in documents {
            try expectSamePaths(xml, chunkSizes: Array(1...12))
            var document: XMLTVError?
            do { _ = try parse(xml, options: Self.strict) } catch { document = error }
            for chunkSize in 1...12 {
                #expect(throws: document!) { try streamDecode(Array(xml.utf8), chunkSize: chunkSize, options: Self.strict) }
            }
        }
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

    /// Content after the root that ends unfinished is reported where it starts, after the
    /// complete comments before it, however many of those an earlier chunk held.
    @Test func unfinishedContentAfterTheRootIsReportedWhereItStarts() throws {
        let xml = "<tv></tv><!--a\nb\nc--><!-- unterminated"
        let report = try expectSamePaths(xml, chunkSizes: Array(1...24)).report
        #expect(report.diagnostics.map(\.byteOffset) == ["<tv></tv><!--a\nb\nc-->".utf8.count])
        #expect(report.diagnostics.map(\.line) == [3])
    }

    /// A problem in text is reported at the bad byte, not the start of the value, even after
    /// line ends and references that decoding changes, and in every kind of text.
    @Test func textProblemsAreReportedWhereTheyAre() throws {
        let head = Array("<tv><programme start=\"20240101000000\" channel=\"c\"><title>t</title><desc>first &amp;\r\nbad".utf8)
        let bad = head.count
        let cases: [(bytes: [UInt8], kind: XMLTVError.Code)] = [
            (head + [0x00] + Array("</desc></programme></tv>".utf8), .invalidCharacter),
            (head + [0xFF] + Array("</desc></programme></tv>".utf8), .invalidUTF8),
            (head + Array("<!---->x".utf8) + [0x01] + Array("</desc></programme></tv>".utf8), .invalidCharacter),
        ]
        for (index, (bytes, kind)) in cases.enumerated() {
            let report = try expectSamePaths(bytes: bytes).report
            let offset = index == 2 ? bad + "<!---->x".utf8.count : bad
            #expect(report.diagnostics.map(\.code) == [kind])
            #expect(report.diagnostics.map(\.byteOffset) == [offset])
            #expect(report.diagnostics.map(\.line) == [2])
            #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(bytes), options: XMLTVOptions(policy: .strict)) }
            do {
                _ = try XMLTVDocument(data: Data(bytes), options: XMLTVOptions(policy: .strict))
            } catch {
                #expect(error.line == 2 && error.column == offset - bad + 4)
            }
        }
        // An attribute value that is decoded first.
        let attribute = Array(#"<tv><channel id="a&amp;"#.utf8) + [0xFF] + Array(#""><display-name>A</display-name></channel></tv>"#.utf8)
        #expect(try expectSamePaths(bytes: attribute).report.diagnostics.map(\.byteOffset) == [#"<tv><channel id="a&amp;"#.utf8.count])
    }

    @Test func truncatedGzipReportsTheCauseBeforeItsEffect() throws {
        let gz = try Fixtures.data("upstream_test.xml.gz")
        let report = try XMLTVDocument(data: gz.prefix(gz.count / 2)).report
        #expect(report.diagnostics.suffix(2).map(\.code) == [.invalidCompressedData, .unexpectedEndOfInput])
    }
}
