import Foundation
import Testing
@testable import XMLTV

@Suite("Model")
struct ModelTests {
    @Test func decodesEveryFieldOfTheUpstreamTestDocument() throws {
        let guide = try XMLTVDocument(contentsOf: Fixtures.url("upstream_test.xml"))
        #expect(guide.info.generatorInfoName == "my listings generator")
        #expect(guide.channels.map(\.id) == ["3sat.de", "das-erste.de"])
        #expect(guide.channels[1].displayNames == [LocalizedText("ARD", language: "de"), LocalizedText("Das Erste", language: "de")])

        let p = try #require(guide.programmes.first)
        #expect(p.channelID == "3sat.de")
        #expect(p.start.precision == .minute && p.start.utcOffsetSeconds == 0)
        #expect(p.titles == [LocalizedText("blah", language: "de"), LocalizedText("blah", language: "en")])
        #expect(p.descriptions == [LocalizedText("Blah Blah Blah.", language: "de")])
        #expect(p.credits.map(\.role) == [.director, .actor, .actor, .actor, .actor, .actor])
        #expect(p.credits.map(\.name) == ["blah", "a", "b", "c", "d", "e"])
        #expect(p.credits[3].character == "blah")
        #expect(p.credits[4].isGuest)
        #expect(p.credits[5].images == [Image(url: "https://www.example.com/xxx.jpg", type: "person")])
        #expect(p.credits[5].urls == [Link("https://www.themoviedb.org/person/204", system: "TMDB")])
        #expect(p.date == "19901011")
        #expect(p.categories == [LocalizedText("Comedy", language: "en")])
        #expect(p.length == .seconds(3600))
        #expect(p.icons == [Icon(source: "http://image.example.com/dgXPhzNJH8H.jpg", width: 500, height: 123)])
        #expect(p.urls == [Link("https://www.example.com/title/0365/"), Link("https://www.example.com/title/tt0365/", system: "IMDb")])
        #expect(p.countries == [LocalizedText("ES")])
        #expect(p.episodeNumbers == [EpisodeNumber(system: "xmltv_ns", value: "2 . 9 . 0/1")])
        let ns = try #require(p.episodeNumbers[0].xmltvNS)
        #expect(ns.displaySeason == 3 && ns.displayEpisode == 10 && ns.part == .init(index: 0, total: 1))
        #expect(p.video == Video(aspect: "16:9"))
        #expect(p.lastChance == LocalizedText(""))
        #expect(p.subtitles == [Subtitles(type: "teletext", language: LocalizedText("English", language: "en"))])
        #expect(p.ratings == [Rating(system: "MPAA", value: "PG")])
        #expect(p.starRatings == [StarRating(value: "3/3", icons: [Icon(source: "stars.png")])])
        #expect(p.starRatings[0].score! == (3, 3))
        #expect(p.reviews == [Review(type: "text", value: "More blah blah", source: "tvreviews", reviewer: "joe", language: "en")])
        #expect(p.images == [
            Image(url: "https://www.example.com/xxxx.jpg"),
            Image(url: "https://www.example.com/xxxx.jpg", type: "backdrop", size: "2", system: "myapp"),
            Image(url: "https://www.example.com/xxxx.jpg", type: "poster", size: "2", orientation: "L", system: "myapp"),
        ])
        #expect(guide.report.diagnosticCount == 0)
    }

    @Test func handlesLatin1CDATANamedZonesAndExtensions() throws {
        let guide = try XMLTVDocument(contentsOf: Fixtures.url("edge_latin1.xml"))
        #expect(guide.report.encoding == .latin1)
        #expect(guide.programmes.map(\.title) == ["Café crème", "☺ ☃ 'q' \"dq\"", "Truncated start"])
        let first = guide.programmes[0]
        #expect(first.descriptions.first?.value == "Raw <b>bold</b> & stuff")
        #expect(first.stop?.precision == .minute)
        #expect(first.episodeNumbers[1].xmltvNS == XMLTVNS("  . 6/22 .  "))
        #expect(first.episodeNumbers[1].xmltvNS?.episode == .init(index: 6, total: 22))
        #expect(first.episodeNumbers[1].xmltvNS?.season == nil)
        #expect(first.previouslyShown?.start?.precision == .second)
        #expect(first.starRatings.first!.score! == (3.5, 5))
        #expect(first.length == .seconds(3600))
        #expect(guide.programmes[1].clump == Clump(index: 1, count: 2))
        #expect(guide.programmes[1].start.utcOffsetSeconds == 3600)
        #expect(guide.programmes[2].start.precision == .year)
        #expect(guide.report.diagnosticCount == 0)
    }

    @Test func exactLatin1HasNoWindows1252Remapping() throws {
        let bytes: [UInt8] = Array(#"<?xml version="1.0" encoding="ISO-8859-1"?><tv><programme start="2024" channel="c"><title>"#.utf8)
            + [0x80, 0xE9] + Array("</title></programme></tv>".utf8)
        let latin1 = try XMLTVDocument(data: Data(bytes))
        #expect(latin1.programmes[0].title == "\u{80}é")
        let windows = try XMLTVDocument(data: Data(bytes), options: .with { $0.encoding = .windows1252 })
        #expect(windows.programmes[0].title == "€é")
    }

    @Test func utf16AndGzipDecodeToTheSameModel() throws {
        let plain = try XMLTVDocument(contentsOf: Fixtures.url("upstream_test.xml"))
        for name in ["utf16le_bom.xml", "utf16be_nobom.xml", "upstream_test.xml.gz"] {
            let other = try XMLTVDocument(contentsOf: Fixtures.url(name))
            #expect(other.programmes == plain.programmes, "\(name)")
            #expect(other.channels == plain.channels, "\(name)")
        }
        // Two gzip members, each a whole document: the second is content after the root.
        let concatenated = try XMLTVDocument(contentsOf: Fixtures.url("concatenated_members.xml.gz"))
        let single = try XMLTVDocument(contentsOf: Fixtures.url("upstream_simple.xml"))
        #expect(concatenated.programmes == single.programmes)
        #expect(concatenated.report.diagnostics.map(\.kind) == [.contentAfterRoot])
    }

    @Test func trimsTextButKeepsInnerWhitespace() throws {
        let guide = try XMLTVDocument(contentsOf: Fixtures.url("upstream_whitespace.xml"))
        #expect(Set(guide.programmes.map(\.title)) == ["T"])
        #expect(Set(guide.programmes.map { $0.descriptions[0].value }) == ["Blah."])
        let multiline = try parse(document(programme("<desc>  one\n    two  </desc>")))
        #expect(multiline.programmes[0].descriptions[0].value == "one\n    two")
    }

    @Test func decodesReferencesOnce() throws {
        let guide = try XMLTVDocument(contentsOf: Fixtures.url("upstream_amp.xml"))
        #expect(guide.programmes[0].titles.map(\.value) == ["Ampersand Land", "&"])
        #expect(guide.programmes[0].descriptions[0].value == "& hello && there &amp; everyone <\n      &< <amp;")
    }

    @Test func normalisesLineEndingsAndAttributeWhitespace() throws {
        let xml = document(programme("<title>a\r\nb\rc</title><desc>x&#13;y</desc>",
                                      attributes: "start=\"20240101120000 +0000\" channel=\"one\ttwo\r\nthree\""))
        let p = try parse(xml).programmes[0]
        #expect(p.title == "a\nb\nc")
        #expect(p.descriptions[0].value == "x\ry")
        let trailing = try parse(document(programme("<title>t</title><desc>end.&#13;</desc>")))
        #expect(trailing.programmes[0].descriptions[0].value == "end.")
        #expect(p.channelID == "one two three")
    }

    @Test func entityDecodedChannelIdentityIsConsistent() throws {
        let xml = document(#"<channel id="A&amp;B"><display-name>x</display-name></channel>"#
            + programme("<title>t</title>", attributes: #"start="2024" channel="A&amp;B""#))
        let guide = try parse(xml, options: .with { $0.channelIDs = ["A&B"] })
        #expect(guide.channels.map(\.id) == ["A&B"])
        #expect(guide.programmes.map(\.channelID) == ["A&B"])
    }

    @Test func mixedContentCredits() throws {
        let xml = document(programme("""
        <title>t</title><credits><actor role="R">  Jane <!-- c --> Doe <image>i.jpg</image><url>u</url> </actor></credits>
        """))
        let credit = try parse(xml).programmes[0].credits[0]
        #expect(credit.name == "Jane  Doe")
        #expect(credit.character == "R" && credit.images.map(\.url) == ["i.jpg"] && credit.urls.map(\.value) == ["u"])
    }

    @Test func toleratesInterleavingReorderingAndExtensions() throws {
        let xml = document("""
        <programme start="2024" channel="b"><icon src="i"/><title>first</title><series-id system="x">1</series-id></programme>
        <channel id="b"><icon src="i"/><display-name>B</display-name></channel>
        <x-extension><programme start="2024" channel="hidden"><title>nested</title></programme></x-extension>
        <programme start="2025" channel="b"><title>second</title><live/></programme>
        """)
        let guide = try parse(xml)
        #expect(guide.programmes.map(\.title) == ["first", "second"])
        #expect(guide.channels.map(\.displayName) == ["B"])
    }

    @Test func recoversRealWorldQuirksWithDiagnostics() throws {
        let xml = document(programme("""
        <title>t</title><rating>12</rating><length units="hours">2.5</length><length units="minutes" />
        """, attributes: #"start="20261113000000+0000" stop="20261113006000+0000" channel="c""#))
        let guide = try parse(xml)
        let p = guide.programmes[0]
        #expect(p.ratings == [Rating(value: "12")])
        #expect(p.length == .seconds(9000))
        #expect(p.duration == .seconds(3600))
        #expect(guide.report.diagnosticCount == 3)
        #expect(throws: XMLTVError.self) { try parse(xml, options: .with { $0.policy = .strict }) }
    }

    @Test func filtersByChannelAndTime() throws {
        let xml = document("""
        <channel id="a"><display-name>A</display-name></channel><channel id="b"><display-name>B</display-name></channel>
        \(programme("<title>a1</title>", attributes: #"start="20240101100000 +0000" stop="20240101110000 +0000" channel="a""#))
        \(programme("<title>b1</title>", attributes: #"start="20240101100000 +0000" stop="20240101110000 +0000" channel="b""#))
        \(programme("<title>a2</title>", attributes: #"start="20240101110000 +0000" stop="20240101120000 +0000" channel="a""#))
        \(programme("<title>a3</title>", attributes: #"start="20240101113000 +0000" channel="a""#))
        """)
        let byChannel = try parse(xml, options: .with { $0.channelIDs = ["a"] })
        #expect(byChannel.channels.map(\.id) == ["a"])
        #expect(byChannel.programmes.map(\.title) == ["a1", "a2", "a3"])

        let start = Date(timeIntervalSince1970: TimeInterval(1_704_103_200))   // 2024-01-01T10:00Z
        let byTime = try parse(xml, options: .with { $0.timeWindow = start.addingTimeInterval(3600)..<start.addingTimeInterval(7200) })
        #expect(byTime.programmes.map(\.title) == ["a2", "a3"])
    }

    @Test func detailsAreCopyOnWriteValues() throws {
        var a = Programme(channelID: "c", start: XMLTVTimestamp(secondsSince1970: 0))
        a.keywords = [LocalizedText("k")]
        var b = a
        b.keywords.append(LocalizedText("l"))
        #expect(a.keywords.count == 1 && b.keywords.count == 2)
        #expect(a != b)
        b.keywords.removeLast()
        #expect(a == b && a.hashValue == b.hashValue)
        #expect(MemoryLayout<Programme>.size <= 224)
    }

    @Test func onscreenEpisodeForms() {
        #expect(EpisodeNumber(value: "S01E05").onscreen! == (1, 5))
        #expect(EpisodeNumber(value: "s2 e10").onscreen! == (2, 10))
        #expect(EpisodeNumber(value: "3x07").onscreen! == (3, 7))
        #expect(EpisodeNumber(value: "E12").onscreen! == (nil, 12))
        #expect(EpisodeNumber(value: "Pilot").onscreen == nil)
        #expect(XMLTVNS("1.2") == nil && XMLTVNS("a.b.c") == nil)
        #expect(XMLTVNS("/13 . . ")?.season == .init(index: nil, total: 13))
    }
}
