import Foundation
import Testing
@testable import XMLTV

/// Input detection and decoding, and options at their extremes.
@Suite("Encodings, compression and options")
struct InputTests {
    static let start = #"start="20240101120000 +0000""#

    @Test func encodingOverrideIgnoresTheDeclaration() throws {
        let xml = #"<?xml version="1.0" encoding="bogus"?><tv><programme start="2024" channel="c"><title>é</title></programme></tv>"#
        #expect(throws: XMLTVError.self) { try parse(xml) }
        let guide = try parse(xml, options: .with { $0.encoding = .utf8 })
        #expect(guide.programmes[0].title == "é")
        var reader = XMLTVReader(data: Data(xml.utf8), options: .with { $0.encoding = .utf8 })
        #expect(try reader.next() != nil)
    }

    /// A declaration of UTF-16 that can be read as ASCII is wrong, not UTF-16: the file is read
    /// as UTF-8, on every path.
    @Test func utf16DeclaredInEightBitTextIsUTF8() throws {
        for name in ["UTF-16", "utf-16le", "UTF-16BE"] {
            let xml = "<?xml version=\"1.0\" encoding=\"\(name)\"?><tv><channel id=\"é\"><display-name>É</display-name></channel></tv>"
            let guide = try parse(xml)
            #expect(guide.report.encoding == .utf8 && guide.channels.map(\.id) == ["é"])
            #expect(try streamDecode(Array(xml.utf8), chunkSize: 3).report == guide.report)
        }
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

    @Test func truncatedGzipDoesNotReserveFromItsLastBytes() throws {
        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03]
        bytes += Array(repeating: 0x55, count: 16) + [0xFF, 0xFF, 0xFF, 0xFF]
        var output = ByteBuffer()
        _ = try bytes.withUnsafeBufferPointer { raw throws(XMLTVError) in try GzipInflater.inflateAll(raw, into: &output) }
        // The trailer says 4 GiB; the buffer is only ever one growth step past the hint.
        #expect(output.capacity < 1 << 20)
    }

    /// The thread limit covers reading the file as well as parsing it.
    @Test func threadLimitAppliesToFileReads() {
        let large = DocumentInput.parallelReadThreshold
        #expect(DocumentInput.readSliceCount(size: large, threads: XMLTVOptions.Parallelism.serial.threadCount) == 1)
        #expect(DocumentInput.readSliceCount(size: large, threads: XMLTVOptions.Parallelism.threads(2).threadCount) == 2)
        #expect(DocumentInput.readSliceCount(size: large, threads: 64) == 8)
        #expect(DocumentInput.readSliceCount(size: large - 1, threads: 64) == 1)
    }

    @Test func threadCountIsHonouredWithoutChangingTheResult() throws {
        let data = Data(ParallelTests.adversarial)
        let serial = try XMLTVDocument(data: data, options: .with { $0.parallelism = .serial })
        for threads in [1, 2, 3] {
            let parallel = try XMLTVDocument(data: data, options: .with { $0.parallelism = .threads(threads) })
            #expect(parallel.programmes == serial.programmes && parallel.report == serial.report)
        }
    }

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
}
