import Foundation
import XMLTV

/// Benchmark harness.
///
///     xmltv-bench <mode> <file> [repetitions]
///
/// Modes:
///   document        XMLTVDocument, default options (read + automatic parallelism)
///   document-mmap   XMLTVDocument with memory-mapped input
///   serial          XMLTVDocument, one thread
///   reader          XMLTVReader, streaming, constant memory
///   filter          XMLTVDocument keeping 1/64 of channels
///   foundation      Foundation XMLParser building the common programme fields
///   chunks          XMLTVItems over 64 KiB Data chunks read from the file
///   bytes           XMLTVItems(bytes:) over URLSession.AsyncBytes of the file URL
///   schedule        XMLTVSchedule built from an already parsed document
///
/// Reports the median and range of wall time over the repetitions. Parse time excludes freeing
/// the result, which is measured separately and reported as teardown.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: xmltv-bench <mode> <file> [repetitions]")
    exit(2)
}
let mode = arguments[1]
let url = URL(fileURLWithPath: arguments[2])
let repetitions = arguments.count > 3 ? Int(arguments[3])! : 5
let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

struct Sample { var parse: Double; var teardown: Double; var summary: String }

func measure(_ body: () throws -> (summary: String, keepAlive: Any)) rethrows -> Sample {
    let clock = ContinuousClock()
    var result: (summary: String, keepAlive: Any)?
    let parse = try clock.measure { result = try body() }
    let summary = result!.summary
    let teardown = clock.measure { result = nil }
    return Sample(parse: seconds(parse), teardown: seconds(teardown), summary: summary)
}

func documentSample(_ options: XMLTVOptions) throws -> Sample {
    try measure {
        let document = try XMLTVDocument(contentsOf: url, options: options)
        return ("\(document.channels.count) channels, \(document.programmes.count) programmes, \(document.report.diagnosticCount) diagnostics", document)
    }
}

func run() throws -> Sample {
    switch mode {
    case "document":
        return try documentSample(XMLTVOptions())
    case "document-mmap":
        var options = XMLTVOptions()
        options.fileAccess = .memoryMapped
        return try documentSample(options)
    case "serial":
        var options = XMLTVOptions()
        options.parallelism = .serial
        return try documentSample(options)
    case "filter":
        var options = XMLTVOptions()
        options.channelIDs = selectedChannels
        return try documentSample(options)
    case "reader":
        return try measure {
            var reader = try XMLTVReader(contentsOf: url)
            var channels = 0, programmes = 0
            while let item = try reader.next() {
                switch item {
                case .channel: channels += 1
                case .programme: programmes += 1
                }
            }
            return ("\(channels) channels, \(programmes) programmes (streamed)", ())
        }
    case "foundation":
        return try measure {
            let builder = FoundationBuilder(url: url)
            let programmes = try builder.parse()
            return ("\(programmes.count) programmes (Foundation XMLParser)", programmes)
        }
    case "chunks":
        return try measure {
            let data = try Data(contentsOf: url)
            let chunks = AsyncStream<Data> { continuation in
                var offset = 0
                while offset < data.count {
                    let end = min(data.count, offset + (64 << 10))
                    continuation.yield(data.subdata(in: offset..<end))
                    offset = end
                }
                continuation.finish()
            }
            let count = try blocking { try await countItems(XMLTVItems(chunks: chunks)) }
            return ("\(count) items (async chunks)", ())
        }
    case "bytes":
        return try measure {
            let count = try blocking {
                let (bytes, _) = try await URLSession.shared.bytes(from: url)
                return try await countItems(XMLTVItems(bytes: bytes))
            }
            return ("\(count) items (URLSession.AsyncBytes)", ())
        }
    case "schedule":
        let document = try XMLTVDocument(contentsOf: url)
        return measure {
            let schedule = XMLTVSchedule(document)
            return ("\(schedule.channelIDs.count) channels, \(document.programmes.count) programmes scheduled", schedule)
        }
    default:
        print("unknown mode \(mode)")
        exit(2)
    }
}

@Sendable func countItems<Chunks>(_ items: XMLTVItems<Chunks>) async throws -> Int {
    var count = 0
    for try await _ in items { count += 1 }
    return count
}

/// Runs async work to completion from synchronous benchmark code.
func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task.detached {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
}

/// Every 64th channel ID, found with a quick pre-pass that is not timed.
let selectedChannels: Set<String> = {
    guard mode == "filter" else { return [] }
    var options = XMLTVOptions()
    options.timeWindow = Date.distantFuture..<Date.distantFuture
    let document = try! XMLTVDocument(contentsOf: url, options: options)
    return Set(document.channels.enumerated().filter { $0.offset % 64 == 0 }.map(\.element.id))
}()

var samples: [Sample] = []
_ = try run()   // warm the page cache and the allocator
for _ in 0..<repetitions { samples.append(try run()) }

let parses = samples.map(\.parse).sorted()
let teardowns = samples.map(\.teardown).sorted()
let median = parses[parses.count / 2]
print(String(
    format: "%@ %@: %@\n  parse median %.1f ms (range %.1f–%.1f) = %.2f GB/s; teardown median %.1f ms",
    mode, url.lastPathComponent, samples[0].summary,
    median * 1000, parses.first! * 1000, parses.last! * 1000,
    Double(fileSize) / median / 1e9, teardowns[teardowns.count / 2] * 1000))
