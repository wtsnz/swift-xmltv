/// The attributes of the root `<tv>` element, which describe where the guide came from.
///
/// Every field is optional in XMLTV, and many feeds set none of them.
public struct TVInfo: Sendable, Hashable {
    /// When the data was produced, as written: often a partial timestamp such as `20240101`.
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
}

/// A `<channel>`: one broadcast channel, which programmes refer to by ``id``.
///
/// XMLTV does not require a programme's channel to be declared. Look channels up by ID, and be
/// prepared for programmes on channels that have no record. Some feeds also declare the same ID
/// twice. Both records are kept, in document order.
public struct Channel: Sendable, Hashable, Identifiable {
    /// The identifier programmes use in their `channel` attribute, such as `BBC.One.uk`. Often,
    /// but not always, a DNS-like name.
    public var id: String
    /// Names for the channel, most preferred first. Valid XMLTV has at least one.
    public var displayNames: [LocalizedText]
    /// Logos, most preferred first.
    public var icons: [Icon]
    /// Web pages about the channel.
    public var urls: [Link]

    public init(id: String, displayNames: [LocalizedText] = [], icons: [Icon] = [], urls: [Link] = []) {
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
public struct LocalizedText: Sendable, Hashable {
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
public struct Icon: Sendable, Hashable {
    /// The `src` attribute: the image URL, as written.
    public var source: String
    /// The image width in pixels, if given.
    public var width: Int?
    /// The image height in pixels, if given.
    public var height: Int?

    public init(source: String, width: Int? = nil, height: Int? = nil) {
        self.source = source
        self.width = width
        self.height = height
    }
}

/// A `<url>`: a web address, with the system it belongs to.
public struct Link: Sendable, Hashable {
    /// The URL, as written. It is a `String` rather than a `URL`, because feeds contain values
    /// that `URL` would reject, and because creating millions of `URL`s is slow.
    public var value: String
    /// The `system` attribute, naming the site or database the link points into, such as `imdb`.
    public var system: String?

    public init(_ value: String, system: String? = nil) {
        self.value = value
        self.system = system
    }
}

/// An `<image>`: a poster, backdrop or photo.
///
/// The classification attributes keep the text written in the source, so values the DTD
/// doesn't list survive.
public struct Image: Sendable, Hashable {
    /// The image URL, as written.
    public var url: String
    /// The `type` attribute: `poster`, `backdrop`, `still`, `person` or `character`.
    public var type: String?
    /// The `size` attribute: `1` (small), `2` (medium) or `3` (large).
    public var size: String?
    /// The `orient` attribute: `P` (portrait) or `L` (landscape).
    public var orientation: String?
    /// The `system` attribute, naming the source of the image.
    public var system: String?

    public init(url: String, type: String? = nil, size: String? = nil, orientation: String? = nil, system: String? = nil) {
        self.url = url
        self.type = type
        self.size = size
        self.orientation = orientation
        self.system = system
    }
}
