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
let byteCount = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue

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

func documentSample(_ options: ParseOptions) throws -> Sample {
    try measure {
        let document = try XMLTVDocument(contentsOf: url, options: options)
        return ("\(document.channels.count) channels, \(document.programmes.count) programmes, \(document.report.diagnosticCount) diagnostics", document)
    }
}

func run() throws -> Sample {
    switch mode {
    case "document":
        return try documentSample(ParseOptions())
    case "document-mmap":
        var options = ParseOptions()
        options.fileAccess = .memoryMapped
        return try documentSample(options)
    case "serial":
        var options = ParseOptions()
        options.parallelism = .serial
        return try documentSample(options)
    case "filter":
        var options = ParseOptions()
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
    default:
        print("unknown mode \(mode)")
        exit(2)
    }
}

/// Every 64th channel ID, found with a quick pre-pass that is not timed.
let selectedChannels: Set<String> = {
    guard mode == "filter" else { return [] }
    var options = ParseOptions()
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
    Double(byteCount) / median / 1e9, teardowns[teardowns.count / 2] * 1000))
