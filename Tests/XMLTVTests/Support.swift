import Foundation
import Testing
@testable import XMLTV

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static let xmlNames = [
        "upstream_amp.xml", "upstream_attrs.xml", "upstream_clump.xml", "upstream_intervals.xml",
        "upstream_overlap.xml", "upstream_simple.xml", "upstream_test.xml", "upstream_test_empty.xml",
        "upstream_test_livre.xml", "upstream_whitespace.xml", "upstream_all_UTF8.expected", "edge_latin1.xml",
    ]

    /// Real-world feeds, from `$XMLTV_CORPUS` or `../Research/samples/real` next to the package.
    /// The tests that use them have no cases when neither exists.
    static let corpusDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["XMLTV_CORPUS"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Research/samples/real")
    }()

    static func corpus(maximumBytes: Int) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: corpusDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { url in
            url.pathExtension == "xml" && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) <= maximumBytes
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

func parse(_ xml: String, options: XMLTVOptions = XMLTVOptions()) throws(XMLTVError) -> XMLTVDocument {
    try XMLTVDocument(data: Data(xml.utf8), options: options)
}

/// Wraps programme markup in a minimal document.
func document(_ body: String) -> String {
    "<?xml version=\"1.0\"?>\n<tv>\n\(body)\n</tv>\n"
}

func programme(_ children: String, attributes: String = #"start="20240101120000 +0000" channel="c1""#) -> String {
    "<programme \(attributes)>\(children)</programme>"
}

extension XMLTVOptions {
    static func with(_ change: (inout XMLTVOptions) -> Void) -> XMLTVOptions {
        var options = XMLTVOptions()
        change(&options)
        return options
    }
}

/// Parses `bytes` with chunks starting at exactly `splits`, bypassing the size thresholds.
func parse(_ bytes: [UInt8], splits: [Int], options: XMLTVOptions = XMLTVOptions()) throws(XMLTVError) -> DocumentDriver.Output {
    try bytes.withUnsafeBufferPointer { buffer throws(XMLTVError) in
        try DocumentDriver.parse(buffer, input: .init(encoding: .utf8, inputByteCount: bytes.count), options: options, splits: [0] + splits + [bytes.count])
    }
}

/// Streams `data` through ``XMLTVItems`` in chunks of `chunkSize` bytes.
func streamItems(_ data: Data, chunkSize: Int, options: XMLTVOptions = XMLTVOptions()) async throws -> [XMLTVItem] {
    try await stream(data, chunkSize: chunkSize, options: options).items
}

/// Streams `data` through ``XMLTVItems`` in chunks of `chunkSize` bytes, keeping the report.
func stream(_ data: Data, chunkSize: Int, options: XMLTVOptions = XMLTVOptions()) async throws -> (items: [XMLTVItem], report: XMLTVReport) {
    let chunks = AsyncStream<Data> { continuation in
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            continuation.yield(data.subdata(in: offset..<end))
            offset = end
        }
        continuation.finish()
    }
    var items: [XMLTVItem] = []
    var iterator = XMLTVItems(chunks: chunks, options: options).makeAsyncIterator()
    while let item = try await iterator.next() { items.append(item) }
    return (items, iterator.report)
}

/// Feeds `bytes` to a ``StreamDecoder`` directly, `chunkSize` bytes at a time.
func streamDecode(_ bytes: [UInt8], chunkSize: Int, options: XMLTVOptions = XMLTVOptions()) throws(XMLTVError) -> (items: [XMLTVItem], report: XMLTVReport) {
    var decoder = StreamDecoder(options: options)
    var items: [XMLTVItem] = []
    var offset = 0
    while true {
        switch try decoder.next() {
        case .item(let item):
            items.append(item)
        case .end:
            return (items, decoder.report)
        case .needsInput:
            if offset < bytes.count {
                let end = min(bytes.count, offset + chunkSize)
                try bytes[offset..<end].withUnsafeBufferPointer { chunk throws(XMLTVError) in try decoder.append(chunk) }
                offset = end
            } else {
                try decoder.finish()
            }
        }
    }
}

extension XMLTVDocument {
    /// Channels and programmes interleaved in the order a streaming reader returns them.
    var items: [XMLTVItem] { channels.map(XMLTVItem.channel) + programmes.map(XMLTVItem.programme) }
}

func sortedByKind(_ items: [XMLTVItem]) -> [XMLTVItem] {
    items.filter { if case .channel = $0 { true } else { false } } + items.filter { if case .programme = $0 { true } else { false } }
}

/// Compresses `text` with gzip(1).
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

/// The byte offset of the first occurrence of `needle` in `text`.
func offset(of needle: String, in text: String) -> Int {
    let haystack = Array(text.utf8), pattern = Array(needle.utf8)
    return (0...(haystack.count - pattern.count)).first { Array(haystack[$0..<($0 + pattern.count)]) == pattern }!
}

/// `data` as a stream of chunks of `size` bytes.
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

/// The report of a serial parse, a parse split at every given offset, and streams at several
/// chunk sizes must all be equal. Returns the serial result.
@discardableResult
func expectSamePaths(_ xml: String, options: XMLTVOptions = XMLTVOptions(), splits: [Int] = [],
                     chunkSizes: [Int] = [1, 2, 3, 7, 64, 4096], sourceLocation: SourceLocation = #_sourceLocation) throws -> DocumentDriver.Output {
    try expectSamePaths(bytes: Array(xml.utf8), options: options, splits: splits, chunkSizes: chunkSizes, sourceLocation: sourceLocation)
}

@discardableResult
func expectSamePaths(bytes: [UInt8], options: XMLTVOptions = XMLTVOptions(), splits: [Int] = [],
                     chunkSizes: [Int] = [1, 2, 3, 7, 64, 4096], sourceLocation: SourceLocation = #_sourceLocation) throws -> DocumentDriver.Output {
    let serial = try parse(bytes, splits: [], options: options)
    for split in splits {
        let parallel = try parse(bytes, splits: [split], options: options)
        #expect(parallel.programmes == serial.programmes, "split \(split)", sourceLocation: sourceLocation)
        #expect(parallel.report == serial.report, "split \(split)", sourceLocation: sourceLocation)
    }
    for chunkSize in chunkSizes {
        let streamed = try streamDecode(bytes, chunkSize: chunkSize, options: options)
        #expect(sortedByKind(streamed.items) == serial.channels.map(XMLTVItem.channel) + serial.programmes.map(XMLTVItem.programme),
                "chunk \(chunkSize)", sourceLocation: sourceLocation)
        #expect(streamed.report == serial.report, "chunk \(chunkSize)", sourceLocation: sourceLocation)
    }
    return serial
}
