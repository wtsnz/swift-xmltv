import Foundation
import Testing
@testable import XMLTV

/// The streaming paths must produce exactly what the whole-document parser produces, however
/// the input is chunked.
@Suite("Streaming")
struct StreamingTests {
    static let fixtures = Fixtures.xmlNames + [
        "upstream_test.xml.gz", "utf16le_bom.xml", "utf16be_nobom.xml", "concatenated_members.xml.gz", "split_members.xml.gz",
    ]

    @Test(arguments: fixtures, [1, 2, 3, 7, 64, 4096])
    func chunkedAsyncItemsMatchDocument(name: String, chunkSize: Int) async throws {
        let data = try Fixtures.data(name)
        let whole = try XMLTVDocument(data: data)
        let streamed = try await stream(data, chunkSize: chunkSize)
        #expect(sortedByKind(streamed.items) == whole.items, "\(name) in \(chunkSize)-byte chunks")
        #expect(streamed.report == whole.report, "\(name) in \(chunkSize)-byte chunks")
    }

    @Test func adversarialDocumentInSmallChunks() async throws {
        let data = Data(ParallelTests.adversarial)
        let whole = try XMLTVDocument(data: data)
        for chunkSize in [1, 13, 1000] {
            let streamed = try await stream(data, chunkSize: chunkSize)
            #expect(sortedByKind(streamed.items) == whole.items, "chunk \(chunkSize)")
            #expect(streamed.report == whole.report, "chunk \(chunkSize)")
        }
    }

    @Test func readerReportsDiagnosticsWithDocumentOffsets() throws {
        let data = Data(ParallelTests.adversarial)
        let whole = try XMLTVDocument(data: data)
        var reader = XMLTVReader(data: data)
        var items: [XMLTVItem] = []
        while let item = try reader.next() { items.append(item) }
        #expect(sortedByKind(items) == whole.items)
        #expect(reader.report.diagnostics == whole.report.diagnostics)
        #expect(reader.report.diagnosticCount == whole.report.diagnosticCount)
        #expect(reader.info == whole.info)
    }

    @Test(arguments: Fixtures.corpus(maximumBytes: 30_000_000))
    func readerMatchesDocumentOnRealFeeds(url: URL) throws {
        let whole = try XMLTVDocument(contentsOf: url)
        var reader = try XMLTVReader(contentsOf: url)
        var channels: [Channel] = [], programmes: [Programme] = []
        while let item = try reader.next() {
            switch item {
            case .channel(let channel): channels.append(channel)
            case .programme(let programme): programmes.append(programme)
            }
        }
        #expect(programmes == whole.programmes)
        #expect(channels == whole.channels)
        #expect(reader.report.diagnosticCount == whole.report.diagnosticCount)
    }

    @Test func upstreamErrorsPassThroughUnchanged() async throws {
        struct Offline: Error {}
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data("<tv><programme start=\"2024\" channel=\"c\"><title>t</title></programme>".utf8))
            continuation.finish(throwing: Offline())
        }
        var titles: [String?] = []
        await #expect(throws: Offline.self) {
            for try await item in XMLTVItems(chunks: chunks) {
                if case .programme(let p) = item { titles.append(p.title) }
            }
        }
        #expect(titles == ["t"])
    }
}
