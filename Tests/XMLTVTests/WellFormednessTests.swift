import Foundation
import Testing
@testable import XMLTV

/// Markup is checked everywhere, including skipped content, and broken markup throws in every mode.
@Suite("Well-formedness")
struct WellFormednessTests {
    static let start = #"start="20240101120000 +0000""#
    static let attributes = #"start="20240101120000 +0000" channel="c""#
    static let strict = XMLTVOptions(policy: .strict)

    @Test func skippedContentIsStillChecked() {
        let filtered = XMLTVOptions.with { $0.channelIDs = ["other"] }
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

    @Test func basicLexicalRulesAreChecked() throws {
        let filtered = XMLTVOptions(channelIDs: ["other"])
        let bodies = [
            "<1bad/>", #"<x ="v"/>"#, "<!-- a -- b -->", "<!DOCTYPE tv>", "<x><!-- a -- b --></x>", #"<x 1a="v"/>"#,
            "<??>", "<? pi?>", "<?1pi?>", "<?pi?x?>", "<?xml version=\"1.0\"?>", "<?XML?>", "<x><??></x>",
        ]
        for body in bodies {
            let xml = "<tv>\(body)</tv>"
            #expect(throws: XMLTVError.self, "\(body)") { try parse(xml) }
            #expect(throws: XMLTVError.self, "\(body)") { try parse(xml, options: filtered) }
            #expect(throws: XMLTVError.self, "\(body)") { try streamDecode(Array(xml.utf8), chunkSize: 3) }
        }
        for prolog in ["<!DOCTYPE tv [<!-- a -- b -->]>", "<??>"] {
            #expect(throws: XMLTVError.self, "\(prolog)") { try parse(prolog + "<tv/>") }
        }
        // Allowed: a comment ending in `-->`, a DOCTYPE before the root with comments and
        // processing instructions in its subset, comments and processing instructions after it,
        // and target names that only start with `xml`.
        let fine = """
            <?xml version="1.0"?><?xml-stylesheet href="a.xsl"?><!DOCTYPE tv [<!-- a "]" --><?pi '?>]>\
            <tv><!-- a - b --><?xmlish?></tv><!-- after -->\n<?pi?>\n<?pi with data ? > here?>
            """
        #expect(try expectSamePaths(fine).report.diagnosticCount == 0)
    }

    @Test func errorPagesAreNotXMLTV() throws {
        let pages = [
            "<!doctype html>\n<html lang=\"en\"><body>x</body></html>",
            "<html lang=en><head><title>502</title></head></html>",
            "]]> not a guide",
        ]
        for page in pages {
            #expect("\(page)") { try parse(page) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
            #expect("\(page)") { try streamDecode(Array(page.utf8), chunkSize: 5) } throws: { ($0 as? XMLTVError)?.kind == .notXMLTV }
        }
    }

    @Test func anythingAfterTheRootIsOneDiagnostic() throws {
        for trailer in ["<a b=c>", "<!bogus>", "<", "<!-- unterminated", "  \n junk", "<![CDATA[x]]>"] {
            let xml = "<tv><programme \(Self.start) channel=\"c\"><title>t</title></programme></tv>\(trailer)"
            let report = try expectSamePaths(xml).report
            #expect(report.diagnostics.map(\.code) == [.contentAfterRoot], "\(trailer)")
            #expect(!report.isTruncated, "\(trailer)")
        }
        let report = try expectSamePaths("<tv/> \n junk").report
        #expect(report.diagnostics.map(\.line) == [2])
        #expect(report.diagnostics[0].byteOffset == "<tv/> \n ".utf8.count)
    }

    @Test func manyAttributesAreAccepted() throws {
        let extra = (0..<100).map { "x\($0)=\"\($0)\"" }.joined(separator: " ")
        let guide = try parse(document("<programme \(Self.attributes) \(extra)><title>t</title></programme>"))
        #expect(guide.programmes.count == 1)
    }
}
