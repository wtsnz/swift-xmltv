import Foundation
import Testing
@testable import XMLTV

/// The streaming paths must produce exactly what the whole-document parser produces, however
/// the input is chunked.
@Suite("Streaming")
struct StreamingTests {
    static let attributes = #"start="20240101120000 +0000" channel="c""#
    static let strict = XMLTVOptions(policy: .strict)
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

    // MARK: Memory and failure

    /// Gzip input is inflated a step at a time, so a feed that compresses extremely well does
    /// not expand into memory all at once.
    @Test func gzipInputIsInflatedOnDemand() throws {
        let record = programme("<title>Looping channel</title>") + "\n"
        let xml = "<tv>\n" + String(repeating: record, count: 120_000) + "</tv>\n"
        let gz = Array(try gzip(xml))
        #expect(gz.count < xml.utf8.count / 100)
        var decoder = StreamDecoder(options: XMLTVOptions())
        gz.withUnsafeBufferPointer { try! decoder.append($0) }
        try decoder.finish()
        var count = 0, peak = 0
        while case .item = try decoder.next() {
            count += 1
            peak = max(peak, decoder.bufferCapacity)
        }
        #expect(count == 120_000)
        #expect(peak < 6 << 20, "buffers peaked at \(peak) bytes for \(xml.utf8.count) bytes of XML")
    }

    /// Whitespace between records is dropped as it arrives, however long the run. Anything
    /// else that would have to be held whole, beyond the limit, throws on every streaming path;
    /// a whole-document parse holds the input anyway, and reads it.
    @Test func streamingMemoryIsBoundedByTheRecordLimit() async throws {
        let limit = 64 << 10
        let options = XMLTVOptions(maximumRecordSize: limit)
        let record = programme("<title>t</title>") + "\n"
        let padded = "<tv>" + record + String(repeating: " ", count: 2 << 20) + record + "</tv>" + String(repeating: "\n", count: 1 << 20)
        var decoder = StreamDecoder(options: options)
        var peak = 0, count = 0
        let bytes = Array(try gzip(padded))
        var offset = 0
        loop: while true {
            switch try decoder.next() {
            case .item: count += 1
            case .end: break loop
            case .needsInput:
                if offset < bytes.count {
                    let end = min(bytes.count, offset + 4096)
                    try bytes[offset..<end].withUnsafeBufferPointer { try decoder.append($0) }
                    offset = end
                } else {
                    try decoder.finish()
                }
            }
            peak = max(peak, decoder.bufferCapacity)
        }
        #expect(count == 2)
        #expect(peak < 4 << 20, "buffers peaked at \(peak) bytes")

        let large = String(repeating: "x", count: 2 * limit)
        for body in ["<!--\(large)-->", "<ext>\(large)</ext>", programme("<title>\(large)</title>")] {
            let xml = "<tv>" + record + body + record + "</tv>"
            #expect(try parse(xml).programmes.count >= 2)
            let isTooLarge: (any Error) -> Bool = { ($0 as? XMLTVError)?.kind == .recordTooLarge(maximumSize: limit) }
            #expect(performing: { try streamDecode(Array(xml.utf8), chunkSize: 4096, options: options) }, throws: isTooLarge)
            #expect(performing: { var reader = XMLTVReader(data: try gzip(xml), options: options); while try reader.next() != nil {} }, throws: isTooLarge)
            await #expect(performing: { _ = try await XMLTVDocument(chunks: chunks(Data(xml.utf8), size: 4096), options: options) }, throws: isTooLarge)
        }
    }

    /// After an error, a reader keeps throwing it, rather than spinning or reading on.
    @Test func readerErrorsAreFinal() throws {
        let gz = try gzip(document(programme("<title>t</title>")))
        var utf16 = Array("\u{FEFF}<tv><programme start=\"2024\" channel=\"c\"><title>t</title></programme></tv>".utf16)
            .flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        utf16.append(0x41)
        for data in [gz.dropLast(6), Data(utf16)] {
            var reader = XMLTVReader(data: Data(data), options: XMLTVOptions(policy: .strict))
            var first: XMLTVError?
            do {
                while try reader.next() != nil {}
            } catch {
                first = error
            }
            let error = try #require(first)
            for _ in 0..<3 {
                #expect(throws: error) { try reader.next() }
            }
        }
    }

    /// A cancelled task gets `CancellationError`, not the part of the guide read so far.
    @Test func cancellationIsNotTruncation() async throws {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(Data("<tv><programme start=\"2024\" channel=\"c\"><title>t</title></programme>".utf8))
        let task = Task {
            try await XMLTVDocument(chunks: chunks)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

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

    @Test func strictStreamingAcceptsEntitiesAtEveryChunkBoundary() throws {
        let xml = document(programme("<title>Tom &amp; Jerry &#233;</title><desc>a &lt; b</desc>") + "\n" + programme(#"<title>x</title>"#, attributes: #"start="20240101120000 +0000" channel="c&amp;d""#))
        let whole = try parse(xml, options: Self.strict)
        #expect(whole.programmes[0].title == "Tom & Jerry é")
        let bytes = Array(xml.utf8)
        for chunkSize in 1...64 {
            let streamed = try streamDecode(bytes, chunkSize: chunkSize, options: Self.strict)
            #expect(streamed.items.count == 2 && streamed.report == whole.report, "chunk \(chunkSize)")
        }
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

    /// An explicit `next()` stays on the caller's actor, as `for try await` does, rather than
    /// hopping off it for every record.
    @MainActor @Test func explicitNextRunsOnTheCallersActor() async throws {
        #if canImport(Darwin)
        let data = try Fixtures.data("upstream_test.xml")
        let source = ProbeChunks(chunks: stride(from: 0, to: data.count, by: 64).map { data.subdata(in: $0..<min(data.count, $0 + 64)) })
        var iterator = XMLTVItems(chunks: source).makeAsyncIterator()
        var count = 0
        while try await iterator.next() != nil { count += 1 }
        #expect(count == (try XMLTVDocument(data: data)).items.count)
        let calls = source.mainThreadCalls.calls.load(ordering: .relaxed)
        #expect(calls > 1 && source.mainThreadCalls.mainThreadCalls.load(ordering: .relaxed) == calls)
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
}
