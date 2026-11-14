import Testing
@testable import XMLTV

@Suite("Scanner")
struct ScannerTests {
    /// Every token, rendered as text, for compact assertions.
    func tokens(_ xml: String) throws -> [String] {
        let bytes = Array(xml.utf8)
        return try bytes.withUnsafeBufferPointer { buffer in
            var scanner = XMLScanner(buffer)
            var result: [String] = []
            while true {
                switch try scanner.next() {
                case .startTag(let name, let isEmpty):
                    var attributes = ""
                    for i in 0..<scanner.attributeCount {
                        let a = scanner.attribute(at: i)
                        attributes += " \(scanner.string(a.name))=\(scanner.string(a.value))\(a.needsDecoding ? "*" : "")"
                    }
                    result.append("<\(scanner.string(name))\(attributes)\(isEmpty ? "/" : "")>")
                case .endTag(let name): result.append("</\(scanner.string(name))>")
                case .text(let range, let needsDecoding): result.append("'\(scanner.string(range))'\(needsDecoding ? "*" : "")")
                case .cdata(let range): result.append("CDATA(\(scanner.string(range)))")
                case .endOfInput: return result
                }
            }
        }
    }

    @Test func elementsAttributesAndText() throws {
        #expect(try tokens(#"<a x="1" y='two'>hi</a><b/>"#) == ["<a x=1 y=two>", "'hi'", "</a>", "<b/>"])
        #expect(try tokens("<a  x = \"1\"\n/>") == ["<a x=1/>"])
        #expect(try tokens("</a >") == ["</a>"])
    }

    @Test func flagsTextThatNeedsDecoding() throws {
        #expect(try tokens("a&amp;b") == ["'a&amp;b'*"])
        #expect(try tokens("a\r\nb") == ["'a\r\nb'*"])
        #expect(try tokens(#"<a v="x&lt;y" w="a&#9;b" n="plain"/>"#) == ["<a v=x&lt;y* w=a&#9;b* n=plain/>"])
        #expect(try tokens("<a v=\"tab\there\"/>") == ["<a v=tab\there*/>"])
    }

    @Test func flagsAcrossVectorBlocks() throws {
        let long = String(repeating: "x", count: 40)
        #expect(try tokens("\(long)&amp;\(long)<a/>") == ["'\(long)&amp;\(long)'*", "<a/>"])
        #expect(try tokens("\(long)<a/>&") == ["'\(long)'", "<a/>", "'&'*"])
    }

    @Test func skipsCommentsProcessingInstructionsAndDoctype() throws {
        let xml = """
        <?xml version="1.0"?><!DOCTYPE tv SYSTEM "x.dtd" [ <!ENTITY e "<>"> ]><!-- <programme> --><a/>
        """
        #expect(try tokens(xml) == ["<a/>"])
    }

    @Test func cdataIsVerbatim() throws {
        #expect(try tokens("<a><![CDATA[<b>&amp;]]></a>") == ["<a>", "CDATA(<b>&amp;)", "</a>"])
    }

    @Test func rejectsMalformedMarkup() {
        for bad in [#"<a x=1>"#, #"<a x>"#, #"<a x="1"y="2">"#, "<a/ >", "<>", "<!BOGUS>"] {
            #expect(throws: XMLTVError.self, "\(bad)") { try tokens(bad) }
        }
    }

    @Test func reportsTruncationDistinctly() {
        for cut in ["<a x=\"1", "<a", "<!-- open", "<![CDATA[ open", "</a"] {
            #expect { try tokens(cut) } throws: { ($0 as? XMLTVError)?.kind == .unexpectedEndOfInput }
        }
    }

    @Test func skipElementIgnoresMarkupInsideCommentsAndCDATA() throws {
        let xml = "<p><x><!-- </p> --><![CDATA[</p>]]><y a='>'/></x></p><after/>"
        let bytes = Array(xml.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            var scanner = XMLScanner(buffer)
            guard case .startTag(let name, false) = try scanner.next() else { Issue.record("expected <p>"); return }
            try scanner.skipElement(named: name)
            guard case .startTag(let after, true) = try scanner.next() else { Issue.record("expected <after/>"); return }
            #expect(scanner.string(after) == "after")
        }
    }

    @Test func classifiesEveryDTDElementName() {
        let names: [(String, XMLTVElement)] = [
            ("tv", .tv), ("channel", .channel), ("display-name", .displayName), ("icon", .icon), ("url", .url),
            ("programme", .programme), ("title", .title), ("sub-title", .subTitle), ("desc", .desc),
            ("credits", .credits), ("date", .date), ("category", .category), ("keyword", .keyword),
            ("language", .language), ("orig-language", .origLanguage), ("length", .length), ("country", .country),
            ("episode-num", .episodeNum), ("video", .video), ("audio", .audio), ("previously-shown", .previouslyShown),
            ("premiere", .premiere), ("last-chance", .lastChance), ("new", .new), ("subtitles", .subtitles),
            ("rating", .rating), ("star-rating", .starRating), ("review", .review), ("image", .image),
            ("director", .director), ("actor", .actor), ("writer", .writer), ("adapter", .adapter),
            ("producer", .producer), ("composer", .composer), ("editor", .editor), ("presenter", .presenter),
            ("commentator", .commentator), ("guest", .guest), ("present", .present), ("colour", .colour),
            ("aspect", .aspect), ("quality", .quality), ("stereo", .stereo), ("value", .value),
            ("titles", .unknown), ("Title", .unknown), ("series-id", .unknown), ("x", .unknown),
        ]
        for (name, expected) in names {
            let tag = Array(name.utf8).withUnsafeBufferPointer { XMLTVElement($0) }
            #expect(tag == expected, "\(name)")
        }
    }

    @Test func searchKernelsMatchScalarReference() {
        // Every length and alignment around the 16-byte vector width, with the needle at every position.
        for length in 0...40 {
            for position in 0...length {
                var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: length + 3)
                if position < length { bytes[position + 1] = UInt8(ascii: "<") }
                bytes.withUnsafeBufferPointer { buffer in
                    let found = ByteSearch.first(UInt8(ascii: "<"), in: buffer.baseAddress!, from: 1, end: length + 1)
                    #expect(found == position + 1, "length \(length) position \(position)")
                }
            }
        }
    }
}
