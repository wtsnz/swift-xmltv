import Foundation
import Testing
@testable import XMLTV

/// The parallel driver's output must equal a serial parse for any choice of split points.
@Suite("Parallel equivalence")
struct ParallelTests {
    /// A document designed to defeat `<programme` split guessing. After each real programme it
    /// adds, in rotation: a commented-out programme, a programme nested in an extension element, a
    /// CDATA section and a processing instruction that contain `<programme`, and a comment right
    /// before the next real programme.
    static let adversarial: [UInt8] = {
        var xml = "<?xml version=\"1.0\"?>\n<!DOCTYPE tv [ <!-- <programme start=\"1\" channel=\"dtd\"> --> ]>\n<tv>\n"
        xml += "<channel id=\"c0\"><display-name>Zero</display-name></channel>\n"
        for i in 0..<400 {
            let channel = "c\(i % 7)"
            let start = String(format: "202401%02d%02d0000 +0000", i % 28 + 1, i % 24)
            xml += """
            <programme start="\(start)" stop="\(start)" channel="\(channel)"><title lang="en">Show \(i) &amp; more</title>\
            <desc>line one
            line two</desc><category>News</category><credits><actor role="r\(i)">Actor \(i)</actor></credits></programme>\n
            """
            switch i % 5 {
            case 0: xml += "<!-- <programme start=\"\(start)\" channel=\"ghost\"><title>ghost</title></programme> -->\n"
            case 1: xml += "<x-wrap><programme start=\"\(start)\" channel=\"nested\"><title>nested</title></programme></x-wrap>\n"
            case 2: xml += "<x-cdata><![CDATA[ <programme start=\"1\" channel=\"cdata\"> ]]></x-cdata>\n"
            case 3: xml += "<?x-pi <programme start=\"1\" channel=\"pi\"> ?>\n"
            default: xml += "<!-- comment directly before -->"
            }
            if i % 50 == 0 { xml += "<channel id=\"c\(i)\"><display-name>Interleaved \(i)</display-name></channel>\n" }
            if i % 97 == 0 { xml += programme("<title>bad stop</title>", attributes: "start=\"\(start)\" stop=\"bogus\" channel=\"\(channel)\"") }
            // Repeated invalid values exercise the caches; a commented-out run of them would
            // exhaust a speculative chunk's diagnostic samples.
            if i % 61 == 0 {
                xml += programme("<title>Long enough to be interned \u{FFFF}</title>", attributes: "start=\"\(start)\" channel=\"bad&bogus;\"")
                xml += "<!--" + String(repeating: programme("<title>t</title>", attributes: #"start="x" channel="ghost""#), count: 3) + "-->"
            }
        }
        xml += "</tv>\n"
        return Array(xml.utf8)
    }()

    /// Offsets of every literal `<programme`, real or not.
    static let candidateSplits: [Int] = {
        let needle = Array("<programme".utf8)
        return (0...(adversarial.count - needle.count)).filter { Array(adversarial[$0..<($0 + needle.count)]) == needle }
    }()

    func expectEqual(_ a: DocumentDriver.Output, _ b: DocumentDriver.Output, _ comment: Comment) {
        #expect(a.programmes == b.programmes, comment)
        #expect(a.channels == b.channels, comment)
        #expect(a.info == b.info, comment)
        #expect(a.report == b.report, comment)
    }

    @Test func serialBaselineIsSane() throws {
        let serial = try parse(Self.adversarial, splits: [])
        #expect(serial.programmes.count == 412)
        #expect(!serial.programmes.contains { ["ghost", "nested", "cdata", "pi", "dtd"].contains($0.channelID) })
        #expect(serial.channels.count == 9)
        #expect(serial.report.diagnosticCount == 19)
    }

    @Test func everyCandidateSplitAtOnce() throws {
        let serial = try parse(Self.adversarial, splits: [])
        expectEqual(try parse(Self.adversarial, splits: Self.candidateSplits), serial, "all \(Self.candidateSplits.count) candidates")
    }

    @Test(arguments: 0..<40)
    func randomSplits(seed: Int) throws {
        var generator = SeededGenerator(seed: UInt64(seed))
        let serial = try parse(Self.adversarial, splits: [])
        let count = Int.random(in: 1...30, using: &generator)
        // Mix plausible candidates with arbitrary byte offsets, including inside tags and text.
        var splits = Set<Int>()
        for _ in 0..<count {
            splits.insert(Bool.random(using: &generator)
                ? Self.candidateSplits.randomElement(using: &generator)!
                : Int.random(in: 1..<Self.adversarial.count, using: &generator))
        }
        expectEqual(try parse(Self.adversarial, splits: splits.sorted()), serial, "seed \(seed)")
    }

    @Test func errorsAreTheSerialErrors() throws {
        var broken = Self.adversarial
        let middle = Self.candidateSplits[Self.candidateSplits.count / 2]
        broken.replaceSubrange(middle..<(middle + 10), with: Array("<programmX".utf8))   // unclosed element
        let serial = #expect(throws: XMLTVError.self) { try parse(broken, splits: []) }
        for splits in [Self.candidateSplits, Array(Self.candidateSplits.suffix(10)), [middle + 3]] {
            let parallel = #expect(throws: XMLTVError.self) { try parse(broken, splits: splits) }
            #expect(parallel == serial)
        }
    }

    @Test func truncationIsTheSerialTruncation() throws {
        let cut = Array(Self.adversarial[..<(Self.adversarial.count * 2 / 3)])
        let serial = try parse(cut, splits: [])
        #expect(serial.report.isTruncated)
        let splits = Self.candidateSplits.filter { $0 < cut.count }
        expectEqual(try parse(cut, splits: splits), serial, "truncated")
    }

    @Test func filtersAreAppliedIdenticallyInEveryChunk() throws {
        let options = XMLTVOptions.with { $0.channelIDs = ["c1", "c3", "nested"] }
        let serial = try parse(Self.adversarial, splits: [], options: options)
        #expect(Set(serial.programmes.map(\.channelID)) == ["c1", "c3"])
        expectEqual(try parse(Self.adversarial, splits: Self.candidateSplits, options: options), serial, "filtered")
    }

    @Test(arguments: Fixtures.corpus(maximumBytes: 30_000_000))
    func realFeedsMatchSerial(url: URL) throws {
        let serial = try XMLTVDocument(contentsOf: url, options: .with { $0.parallelism = .serial })
        let parallel = try XMLTVDocument(contentsOf: url, options: .with { $0.parallelism = .threads(16) })
        #expect(parallel.programmes == serial.programmes)
        #expect(parallel.channels == serial.channels)
        #expect(parallel.report == serial.report)
    }
}

/// SplitMix64, so random tests are reproducible from their seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
