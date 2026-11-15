import Foundation
import Testing
@testable import XMLTV

@Suite("Robustness")
struct RobustnessTests {
    static let sample: String = document((0..<30).map { i in
        programme("<title>p\(i)</title><desc>d&amp;\(i)</desc><credits><actor>a</actor></credits><rating><value>PG</value></rating>",
                  attributes: "start=\"20240101\(String(format: "%02d", i % 24))0000 +0000\" channel=\"c\(i % 3)\"")
    }.joined(separator: "\n"))

    /// A download cut off anywhere keeps exactly the programmes that were complete.
    @Test func everyTruncationKeepsTheCompleteRecords() async throws {
        let bytes = Array(Self.sample.utf8)
        let full = try parse(Self.sample)
        let rootEnd = Array("<?xml version=\"1.0\"?>\n<tv>".utf8).count
        for cut in stride(from: rootEnd, to: bytes.count, by: 3) {
            let prefix = Data(bytes[..<cut])
            let partial = try XMLTVDocument(data: prefix)
            #expect(partial.programmes == Array(full.programmes.prefix(partial.programmes.count)), "cut \(cut)")
            let complete = Array("</tv>".utf8)
            let isWhole = bytes[..<cut].suffix(complete.count).elementsEqual(complete)
            #expect(partial.report.isTruncated == !isWhole, "cut \(cut)")
            #expect(throws: XMLTVError.self) { try XMLTVDocument(data: prefix, options: .with { $0.policy = .strict }) }

            let streamed = try await streamItems(prefix, chunkSize: 11)
            #expect(sortedByKind(streamed) == partial.items, "streamed cut \(cut)")
        }
    }

    @Test func emptyOrForeignInputIsNotXMLTV() {
        for input in ["", "   ", "<?xml version=\"1.0\"?>", "<rss></rss>", "<tv"] {
            #expect(throws: XMLTVError.self, "\(input)") { try parse(input) }
        }
        #expect { try parse("<rss></rss>") } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
    }

    @Test func structuralDamageAlwaysThrows() {
        let cases = [
            document(programme("<title>one</desc>")),
            document(programme("<title x=1>t</title>")),
            document("<programme start=\"2024\" channel=\"c\"><title>t</title></tv>"),
            "<tv><channel id=\"a\"></tv>",
            "text<tv></tv>",
        ]
        for xml in cases {
            #expect(throws: XMLTVError.self, "\(xml)") { try parse(xml) }
        }
    }

    @Test func errorsCarryLineAndColumn() {
        let xml = "<tv>\n  <programme start=\"2024\" channel=\"c\">\n    <title>t</titel>\n  </programme>\n</tv>"
        #expect {
            try parse(xml)
        } throws: { error in
            guard let error = error as? XMLTVError, case .mismatchedEndTag(expected: "title", found: "titel") = error.kind else { return false }
            return error.line == 3 && error.column == 13
        }
    }

    @Test func missingRequiredDataDropsTheRecordInLenientMode() throws {
        let xml = document("""
        <programme channel="c"><title>no start</title></programme>
        <programme start="2024"><title>no channel</title></programme>
        <programme start="garbage" channel="c"><title>bad start</title></programme>
        <channel><display-name>no id</display-name></channel>
        <programme start="2024" channel="c"><title>kept</title><icon/><review>r</review></programme>
        """)
        let guide = try parse(xml)
        #expect(guide.programmes.map(\.title) == ["kept"])
        #expect(guide.channels.isEmpty)
        #expect(guide.report.diagnosticCount == 6)
        #expect(throws: XMLTVError.self) { try parse(xml, options: .with { $0.policy = .strict }) }
    }

    @Test func unknownAndForbiddenReferences() throws {
        let guide = try parse(document(programme("<title>a &nbsp; b &#0; c &#x110000; d &#xD800; &bogus</title>")))
        #expect(guide.programmes[0].title == "a &nbsp; b &#0; c &#x110000; d &#xD800; &bogus")
        #expect(guide.report.diagnosticCount == 5)
    }

    @Test func invalidUTF8IsRepairedAndReported() throws {
        let bytes = Array(document(programme("<title>X</title>")).utf8)
        let index = bytes.firstIndex(of: UInt8(ascii: "X"))!
        var broken = bytes
        broken.replaceSubrange(index...index, with: [0xC3, 0x28])
        let guide = try XMLTVDocument(data: Data(broken))
        #expect(guide.programmes[0].title == "\u{FFFD}(")
        #expect(guide.report.diagnostics.map(\.kind) == [.invalidUTF8])
        #expect(throws: XMLTVError.self) { try XMLTVDocument(data: Data(broken), options: .with { $0.policy = .strict }) }
    }

    @Test func diagnosticsAreCappedButCounted() throws {
        let body = (0..<50).map { _ in programme("<title>t</title>", attributes: #"start="bad" channel="c""#) }.joined()
        let guide = try parse(document(body), options: .with { $0.diagnosticLimit = 10 })
        #expect(guide.report.diagnostics.count == 10)
        #expect(guide.report.diagnosticCount == 50)
        #expect(guide.report.diagnostics.map(\.line) == Array(repeating: 3, count: 10))
    }

    @Test func randomByteMutationsNeverCrash() throws {
        var generator = SeededGenerator(seed: 7)
        let bytes = Array(try Fixtures.data("upstream_test.xml"))
        for _ in 0..<3000 {
            var mutated = bytes
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<mutated.count, using: &generator)
                mutated[index] = [UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "&"), UInt8(ascii: "\""), 0xFF, 0x00, UInt8(ascii: "/")]
                    .randomElement(using: &generator)!
            }
            _ = try? XMLTVDocument(data: Data(mutated))
            _ = try? XMLTVDocument(data: Data(mutated), options: .with { $0.policy = .strict })
        }
    }

    /// Mutated documents give the same records, report or error on every path: serial, split
    /// at a random byte, and streamed in small chunks, in both policies. Crashing is not the
    /// only failure; disagreeing is one too.
    @Test func mutatedDocumentsAgreeOnEveryPath() throws {
        enum Outcome: Equatable {
            case parsed([XMLTVItem], XMLTVReport)
            case failed(XMLTVError)
        }
        func outcome(_ body: () throws(XMLTVError) -> (items: [XMLTVItem], report: XMLTVReport)) -> Outcome {
            do {
                let result = try body()
                return .parsed(sortedByKind(result.items), result.report)
            } catch {
                return .failed(error)
            }
        }
        var generator = SeededGenerator(seed: 11)
        let base = Array(Self.sample.utf8)
        let replacements: [UInt8] = Array("<>/&\"'= \n!?-[]x".utf8) + [0x0D, 0x00, 0xC3, 0xFF]
        for _ in 0..<400 {
            var bytes = base
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: bytes[index] = replacements.randomElement(using: &generator)!
                case 1: bytes.remove(at: index)
                default: bytes.insert(replacements.randomElement(using: &generator)!, at: index)
                }
            }
            let split = Int.random(in: 1..<bytes.count, using: &generator)
            for policy in [XMLTVOptions.Policy.lenient, .strict] {
                let options = XMLTVOptions(policy: policy)
                func items(_ output: DocumentDriver.Output) -> (items: [XMLTVItem], report: XMLTVReport) {
                    (output.channels.map(XMLTVItem.channel) + output.programmes.map(XMLTVItem.programme), output.report)
                }
                let serial = outcome { () throws(XMLTVError) in items(try parse(bytes, splits: [], options: options)) }
                let parallel = outcome { () throws(XMLTVError) in items(try parse(bytes, splits: [split], options: options)) }
                #expect(parallel == serial, "split at \(split), \(policy)")
                for chunkSize in [1, 5, 64] {
                    let streamed = outcome { () throws(XMLTVError) in try streamDecode(bytes, chunkSize: chunkSize, options: options) }
                    #expect(streamed == serial, "chunk \(chunkSize), \(policy)")
                }
            }
        }
    }
}
