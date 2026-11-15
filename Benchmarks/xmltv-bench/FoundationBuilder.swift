import Foundation
#if canImport(FoundationXML)
import FoundationXML   // XMLParser, on Linux
#endif
import XMLTV

/// A baseline that builds the common programme fields with Foundation's `XMLParser`: channel,
/// times, titles, sub-titles, descriptions, categories, date, episode numbers, credits, icons,
/// ratings and star ratings. It skips the rare DTD fields and channel records, so it does less
/// work than the library. This is how most Swift code reads XMLTV today. Timestamps use plain integer arithmetic, so the
/// comparison measures XML parsing and model building, not date formatting.
final class FoundationBuilder: NSObject, XMLParserDelegate {
    private let url: URL
    private var programmes: [Programme] = []
    private var current: Programme?
    private var text = ""
    private var language: String?
    private var ratingSystem: String?
    private var isStarRating = false
    private var episodeSystem = "onscreen"
    private var creditRole: Programme.Credit.Role?

    init(url: URL) { self.url = url }

    func parse() throws -> [Programme] {
        let parser = XMLParser(contentsOf: url)!
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return programmes
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        language = attributes["lang"]
        switch name {
        case "programme":
            current = Programme(
                channelID: attributes["channel"] ?? "",
                start: Self.timestamp(attributes["start"]) ?? XMLTVTimestamp(secondsSince1970: 0),
                stop: Self.timestamp(attributes["stop"]))
        case "rating", "star-rating":
            ratingSystem = attributes["system"]
            isStarRating = name == "star-rating"
        case "episode-num": episodeSystem = attributes["system"] ?? "onscreen"
        case "icon": if let src = attributes["src"] { current?.icons.append(Icon(src)) }
        case "director": creditRole = .director
        case "actor": creditRole = .actor
        case "writer": creditRole = .writer
        case "producer": creditRole = .producer
        case "presenter": creditRole = .presenter
        case "composer": creditRole = .composer
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "programme": if let current { programmes.append(current) }; current = nil
        case "title": current?.titles.append(LocalizedText(value, language: language))
        case "sub-title": current?.episodeTitles.append(LocalizedText(value, language: language))
        case "desc": current?.descriptions.append(LocalizedText(value, language: language))
        case "category": current?.categories.append(LocalizedText(value, language: language))
        case "date": current?.date = value
        case "episode-num": current?.episodeNumbers.append(Programme.EpisodeNumber(value, system: episodeSystem))
        case "value" where isStarRating: current?.starRatings.append(Programme.StarRating(value, system: ratingSystem))
        case "value": current?.ratings.append(Programme.Rating(value, system: ratingSystem))
        case "director", "actor", "writer", "producer", "presenter", "composer":
            if let creditRole { current?.credits.append(Programme.Credit(value, role: creditRole)) }
        default: break
        }
        text = ""
    }

    /// `YYYYMMDDhhmmss ±HHMM` with plain integer arithmetic, so that date handling is not what
    /// this baseline measures.
    static func timestamp(_ text: String?) -> XMLTVTimestamp? {
        guard let text else { return nil }
        let utf8 = Array(text.utf8)
        guard utf8.count >= 14 else { return nil }
        func field(_ i: Int, _ n: Int) -> Int { utf8[i..<(i + n)].reduce(0) { $0 * 10 + Int($1) - 48 } }
        let year = field(0, 4), month = field(4, 2), day = field(6, 2)
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        var offset = 0
        if utf8.count >= 19, let sign = utf8.last(where: { $0 == 43 || $0 == 45 }) {
            let o = utf8.count - 4
            offset = (field(o, 2) * 3600 + field(o + 2, 2) * 60) * (sign == 45 ? -1 : 1)
        }
        let seconds = days * 86_400 + field(8, 2) * 3600 + field(10, 2) * 60 + field(12, 2) - offset
        return XMLTVTimestamp(secondsSince1970: Int64(seconds), utcOffsetSeconds: offset)
    }
}
