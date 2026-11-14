import Foundation
import Testing
import XMLTV

/// Compares the parser with an independent reference built on Foundation's `XMLParser`, which
/// uses libxml2. The reference does its own encoding handling, entity decoding and date
/// arithmetic (via `DateFormatter`). It shares no code with the library.
@Suite("Differential against Foundation")
struct DifferentialTests {
    @Test(arguments: Fixtures.xmlNames)
    func fixtures(name: String) throws {
        try compare(Fixtures.url(name))
    }

    @Test(arguments: Fixtures.corpus(maximumBytes: 30_000_000))
    func realFeeds(url: URL) throws {
        try compare(url)
    }

    func compare(_ url: URL) throws {
        let reference = ReferenceDecoder(url: url).decode()
        let ours = try XMLTVDocument(contentsOf: url).programmes.map(canonical)
        #expect(ours.count == reference.count, "\(url.lastPathComponent)")
        var mismatches = 0
        for (a, b) in zip(ours, reference) where !Self.matches(a, b) {
            mismatches += 1
            if mismatches <= 3 {
                let x = a.components(separatedBy: " | "), y = b.components(separatedBy: " | ")
                let fields = zip(x, y).enumerated().filter { $0.element.0 != $0.element.1 }
                    .map { "field \($0.offset):\n    ours: \($0.element.0.debugDescription)\n     ref: \($0.element.1.debugDescription)" }
                let detail = fields.joined(separator: "\n")
                Issue.record("\(url.lastPathComponent) programme \(x[0]) at \(x[1]):\n\(detail)")
            }
        }
        #expect(mismatches == 0)
    }

    /// Field-by-field equality, where `-` (a time the other side cannot express exactly) matches
    /// anything.
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = a.components(separatedBy: " | "), y = b.components(separatedBy: " | ")
        return x.count == y.count && zip(x, y).enumerated().allSatisfy { index, pair in
            pair.0 == pair.1 || ((index == 1 || index == 2) && (pair.0 == "-" || pair.1 == "-"))
        }
    }

    /// One line per programme covering identity, times and the common fields.
    func canonical(_ p: Programme) -> String {
        func texts(_ values: [LocalizedText]) -> String { values.map { "\($0.language ?? "")=\($0.value)" }.joined(separator: ";") }
        let start = p.start.precision == .second ? String(p.start.secondsSince1970) : "-"
        let stop = p.stop.map { $0.precision == .second ? String($0.secondsSince1970) : "-" } ?? "nil"
        return [
            p.channelID, start, stop, texts(p.titles), texts(p.subTitles), texts(p.descriptions), texts(p.categories),
            p.episodeNumbers.map { "\($0.system)=\($0.value)" }.joined(separator: ";"),
            p.credits.map { "\($0.role)=\($0.name)/\($0.character ?? "")" }.joined(separator: ";"),
            p.ratings.map { "\($0.system ?? "")=\($0.value)" }.joined(separator: ";"),
            p.icons.map(\.source).joined(separator: ";"),
        ].joined(separator: " | ")
    }
}

/// The reference decoder. It keeps each element's direct text, so a credit's name excludes the
/// text of its `<image>` and `<url>` children, as the DTD's mixed-content model intends.
final class ReferenceDecoder: NSObject, XMLParserDelegate {
    let url: URL
    private var results: [String] = []
    private var stack: [(name: String, attributes: [String: String], text: String)] = []
    private var fields: [String: [String]] = [:]
    private var programme: [String: String]?

    private static let formatters: [DateFormatter] = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    init(url: URL) { self.url = url }

    func decode() -> [String] {
        let parser = XMLParser(contentsOf: url)!
        parser.delegate = self
        if !parser.parse() { Issue.record("reference parser failed on \(url.lastPathComponent): \(String(describing: parser.parserError))") }
        return results
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        // Only direct children of <tv> are records. Programmes nested in extensions are not.
        if name == "programme" && stack.count == 1 {
            programme = attributes
            fields = [:]
        }
        stack.append((name, attributes, ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: data, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = stack.removeLast()
        guard programme != nil else { return }
        let text = Self.trim(element.text)
        let parent = stack.last?.name
        let lang = element.attributes["lang"] ?? ""
        switch (name, parent) {
        case ("title", "programme"), ("sub-title", "programme"), ("desc", "programme"), ("category", "programme"):
            fields[name, default: []].append("\(lang)=\(text)")
        case ("episode-num", "programme"):
            fields[name, default: []].append("\(element.attributes["system"] ?? "onscreen")=\(text)")
        case (let role, "credits") where ["director", "actor", "writer", "adapter", "producer", "composer", "editor", "presenter", "commentator", "guest"].contains(role):
            fields["credits", default: []].append("\(role)=\(text)/\(role == "actor" ? element.attributes["role"] ?? "" : "")")
        case ("value", "rating"):
            if stack.count >= 2, stack[stack.count - 2].name == "programme" {
                fields["rating", default: []].append("\(stack.last!.attributes["system"] ?? "")=\(text)")
            }
        case ("icon", "programme"):
            if let source = element.attributes["src"] { fields["icon", default: []].append(source) }
        case ("programme", "tv"):
            let p = programme!
            results.append([
                p["channel"] ?? "", Self.instant(p["start"]), p["stop"].map(Self.instant) ?? "nil",
                join("title"), join("sub-title"), join("desc"), join("category"), join("episode-num"),
                join("credits"), join("rating"), join("icon"),
            ].joined(separator: " | "))
            programme = nil
        default:
            break
        }
    }

    private func join(_ key: String) -> String { (fields[key] ?? []).joined(separator: ";") }

    private static func instant(_ text: String?) -> String {
        guard let text else { return "nil" }
        for formatter in formatters {
            if let date = formatter.date(from: text) { return String(Int64(date.timeIntervalSince1970)) }
        }
        return "-"
    }

    /// Trims XML whitespace only. Foundation's character sets include more, such as NBSP.
    private static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let isSpace: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let first = scalars.firstIndex(where: { !isSpace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isSpace($0) })!
        return String(scalars[first...last])
    }
}
