import Foundation

/// The attributes of the root `<tv>` element, which describe where the guide came from.
///
/// Every field is optional in XMLTV, and many feeds set none of them.
public struct TVInfo: Sendable, Hashable {
    /// When the data was produced, as written: often a partial timestamp such as `20240101`.
    /// See ``creationDate`` for the parsed value.
    public var date: String?
    /// The `source-info-url` attribute: a page describing the data source.
    public var sourceInfoURL: String?
    /// The `source-info-name` attribute: the name of the data source.
    public var sourceInfoName: String?
    /// The `source-data-url` attribute: where the raw data was fetched from.
    public var sourceDataURL: String?
    /// The `generator-info-name` attribute: the program that wrote the file, such as a grabber.
    public var generatorInfoName: String?
    /// The `generator-info-url` attribute: a page about that program.
    public var generatorInfoURL: String?

    public init(
        date: String? = nil, sourceInfoURL: String? = nil, sourceInfoName: String? = nil,
        sourceDataURL: String? = nil, generatorInfoName: String? = nil, generatorInfoURL: String? = nil
    ) {
        self.date = date
        self.sourceInfoURL = sourceInfoURL
        self.sourceInfoName = sourceInfoName
        self.sourceDataURL = sourceDataURL
        self.generatorInfoName = generatorInfoName
        self.generatorInfoURL = generatorInfoURL
    }

    /// ``date`` parsed, keeping its precision. Nil when there is no date or it does not parse.
    public var creationDate: XMLTVTimestamp? {
        date.flatMap { try? XMLTVTimestamp($0, policy: .lenient) }
    }
}

/// A `<channel>`: one broadcast channel, which programmes refer to by ``id``.
///
/// XMLTV does not require a programme's channel to be declared. Look channels up by ID, and be
/// prepared for programmes on channels that have no record.
public struct Channel: Sendable, Hashable, Identifiable {
    /// The identifier programmes use in their `channel` attribute, such as `BBC.One.uk`. Often,
    /// but not always, a DNS-like name.
    ///
    /// IDs are not unique in every feed. Merged feeds in particular declare some channels twice,
    /// often with different details, and both records are kept in document order. Before using
    /// ``XMLTVDocument/channels`` where IDs must be unique, such as a SwiftUI `List`, keep one
    /// record per ID, for example with ``XMLTVDocument/channel(id:)``, which returns the first.
    public var id: String
    /// Names for the channel, most preferred first. Valid XMLTV has at least one.
    public var displayNames: [LocalizedText]
    /// Logos, most preferred first.
    public var icons: [Icon]
    /// Web pages about the channel.
    public var urls: [URLReference]

    public init(id: String, displayNames: [LocalizedText] = [], icons: [Icon] = [], urls: [URLReference] = []) {
        self.id = id
        self.displayNames = displayNames
        self.icons = icons
        self.urls = urls
    }

    /// The first display name.
    public var displayName: String? { displayNames.first?.value }
}

/// Text with an optional language code, as used by `title`, `desc`, `category` and other
/// elements that may appear once per language.
///
/// To choose between languages, call `preferred(for:)` on the array.
public struct LocalizedText: Sendable, Hashable, Codable {
    /// The text, trimmed of leading and trailing whitespace, with entities decoded.
    public var value: String
    /// The `lang` attribute as written, such as `en` or `fr_FR`. XMLTV does not normalise these.
    public var language: String?

    public init(_ value: String, language: String? = nil) {
        self.value = value
        self.language = language
    }
}

/// An `<icon>`: an image URL with optional pixel dimensions.
public struct Icon: Sendable, Hashable, Codable {
    /// The `src` attribute: the image URL as written. See ``url`` for a `URL`.
    public var urlString: String
    /// The image width in pixels, if given.
    public var width: Int?
    /// The image height in pixels, if given.
    public var height: Int?

    public init(_ urlString: String, width: Int? = nil, height: Int? = nil) {
        self.urlString = urlString
        self.width = width
        self.height = height
    }

    /// The image URL, as `URL(string:)` reads ``urlString``. That percent-encodes most text
    /// rather than rejecting it, so a non-nil result is not proof of a usable address.
    public var url: URL? { URL(string: urlString) }
}

/// A `<url>`: a web address, with the system it belongs to. Named `URLReference` rather than
/// `Link` so it does not clash with SwiftUI's `Link`.
///
/// ``Icon``, ``Programme/Image`` and `URLReference` all store their address as `urlString` and
/// convert it on demand with `url`. The text is kept because feeds contain values that `URL`
/// rejects, and because creating millions of `URL`s during a parse is slow.
public struct URLReference: Sendable, Hashable, Codable {
    /// The URL as written. See ``url`` for a `URL`.
    public var urlString: String
    /// The `system` attribute, naming the site or database the link points into, such as `imdb`.
    public var system: String?

    public init(_ urlString: String, system: String? = nil) {
        self.urlString = urlString
        self.system = system
    }

    /// The URL, as `URL(string:)` reads ``urlString``. That percent-encodes most text rather
    /// than rejecting it, so a non-nil result is not proof of a usable address.
    public var url: URL? { URL(string: urlString) }
}

extension Array where Element == LocalizedText {
    /// The text in the first of `languages` that is available. When none is, the first text
    /// with no `lang` attribute, which is usually in the feed's main language, or else the
    /// first element.
    ///
    /// ```swift
    /// let title = programme.titles.preferred()?.value      // in the user's languages
    /// let german = programme.titles.preferred(for: ["de"])
    /// ```
    ///
    /// Language codes are compared without regard to case or to `-` and `_`, so `en-GB` matches
    /// `en_GB`. A code also matches text in the same base language: `en-NZ` matches `en`, and
    /// `en` matches `en_GB`. An exact match is preferred over a base-language one. Text with no
    /// `lang` attribute matches no code.
    ///
    /// - Parameter languages: Language codes, most preferred first. The default is the user's
    ///   preferred languages, such as `["en-NZ", "fr-FR"]`.
    /// - Returns: Nil only when the array is empty.
    public func preferred(for languages: [String] = Locale.preferredLanguages) -> LocalizedText? {
        func normalized(_ code: String) -> Substring {
            Substring(code.lowercased().replacingOccurrences(of: "_", with: "-"))
        }
        func base(_ code: Substring) -> Substring { code.prefix { $0 != "-" } }
        let available = map { $0.language.map(normalized) }
        for language in languages.map(normalized) {
            if let index = available.firstIndex(where: { $0 == language }) { return self[index] }
            if let index = available.firstIndex(where: { $0.map(base) == base(language) }) { return self[index] }
        }
        return first { $0.language == nil } ?? first
    }
}
