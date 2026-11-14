/// A `<programme>`: one broadcast of a show on a channel, over the half-open interval
/// `start ..< stop`.
///
/// Programmes are not sorted or grouped by the parser. They keep the order of the source, which
/// is usually grouped by channel and then sorted by time, but not always.
///
/// The fields most feeds fill in are stored inline. The DTD's less common fields live in one
/// shared, copy-on-write allocation that exists only for programmes that use them. That keeps the
/// struct small: a multi-gigabyte guide holds millions of these, and most of them carry only a
/// title, a description and a few categories. Both kinds of field read and write the same way.
public struct Programme: Sendable, Hashable {
    /// The ``Channel/id`` of the channel showing it.
    public var channelID: String
    /// When the broadcast starts.
    public var start: XMLTVTimestamp
    /// When the broadcast ends, if the source says. Without it, a programme usually runs until
    /// the next one on its channel starts. The parser does not infer that, because schedules can
    /// overlap or have gaps.
    public var stop: XMLTVTimestamp?
    /// Titles, one per language, most preferred first. Valid XMLTV has at least one.
    public var titles: [LocalizedText]
    /// Episode titles.
    public var subTitles: [LocalizedText]
    /// Descriptions. A source may give several in one language, for example a short one and a
    /// long one.
    public var descriptions: [LocalizedText]
    /// Cast and crew in billing order.
    public var credits: [Credit]
    /// The production date. XMLTV dates are often partial (`2024`, `200807`), so this is the text
    /// as written.
    public var date: String?
    /// Genres and other categories, as written.
    public var categories: [LocalizedText]
    /// Episode numbers, one per numbering system.
    public var episodeNumbers: [EpisodeNumber]
    /// Images for the programme, most preferred first.
    public var icons: [Icon]
    /// Content classifications, such as `PG`.
    public var ratings: [Rating]
    /// Critics' scores.
    public var starRatings: [StarRating]
    /// Present when the programme is a repeat.
    public var previouslyShown: PreviouslyShown?
    var details: Details

    public init(channelID: String, start: XMLTVTimestamp, stop: XMLTVTimestamp? = nil) {
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.titles = []
        self.subTitles = []
        self.descriptions = []
        self.credits = []
        self.date = nil
        self.categories = []
        self.episodeNumbers = []
        self.icons = []
        self.ratings = []
        self.starRatings = []
        self.previouslyShown = nil
        self.details = Details()
    }

    /// The first title.
    public var title: String? { titles.first?.value }

    /// The scheduled running time, if both ends are known.
    public var duration: Duration? {
        stop.map { .seconds($0.secondsSince1970 - start.secondsSince1970) }
    }

    // MARK: Less common fields

    /// Keywords describing the content.
    public var keywords: [LocalizedText] {
        get { details.fields.keywords } set { details.update { $0.keywords = newValue } }
    }
    /// The language the programme is broadcast in.
    public var language: LocalizedText? {
        get { details.fields.language } set { details.update { $0.language = newValue } }
    }
    /// The language the programme was made in, when it differs, as for a dubbed film.
    public var originalLanguage: LocalizedText? {
        get { details.fields.originalLanguage } set { details.update { $0.originalLanguage = newValue } }
    }
    /// The `<length>` element: the programme's own running time, without advertisements.
    public var length: Duration? {
        get { details.fields.length } set { details.update { $0.length = newValue } }
    }
    /// Web pages about the programme.
    public var urls: [URLReference] {
        get { details.fields.urls } set { details.update { $0.urls = newValue } }
    }
    /// Countries where the programme was made.
    public var countries: [LocalizedText] {
        get { details.fields.countries } set { details.update { $0.countries = newValue } }
    }
    /// Picture details.
    public var video: Video? {
        get { details.fields.video } set { details.update { $0.video = newValue } }
    }
    /// Sound details.
    public var audio: Audio? {
        get { details.fields.audio } set { details.update { $0.audio = newValue } }
    }
    /// `<premiere>`. Present (possibly with empty text) when this is a premiere.
    public var premiere: LocalizedText? {
        get { details.fields.premiere } set { details.update { $0.premiere = newValue } }
    }
    /// `<last-chance>`. Present (possibly with empty text) when this is the final showing.
    public var lastChance: LocalizedText? {
        get { details.fields.lastChance } set { details.update { $0.lastChance = newValue } }
    }
    /// `<new />`: the first showing of a brand-new programme.
    public var isNew: Bool {
        get { details.fields.isNew } set { details.update { $0.isNew = newValue } }
    }
    /// Subtitle streams.
    public var subtitles: [Subtitles] {
        get { details.fields.subtitles } set { details.update { $0.subtitles = newValue } }
    }
    /// Reviews, or links to them.
    public var reviews: [Review] {
        get { details.fields.reviews } set { details.update { $0.reviews = newValue } }
    }
    /// Posters, backdrops and stills.
    public var images: [Image] {
        get { details.fields.images } set { details.update { $0.images = newValue } }
    }
    /// The `pdc-start` attribute: the Programme Delivery Control start time, for recorders.
    public var pdcStart: XMLTVTimestamp? {
        get { details.fields.pdcStart } set { details.update { $0.pdcStart = newValue } }
    }
    /// The `vps-start` attribute: the Video Programming System start time, for recorders.
    public var vpsStart: XMLTVTimestamp? {
        get { details.fields.vpsStart } set { details.update { $0.vpsStart = newValue } }
    }
    /// The `showview` attribute: a ShowView recording code.
    public var showView: String? {
        get { details.fields.showView } set { details.update { $0.showView = newValue } }
    }
    /// The `videoplus` attribute: a VideoPlus+ recording code.
    public var videoPlus: String? {
        get { details.fields.videoPlus } set { details.update { $0.videoPlus = newValue } }
    }
    /// The `clumpidx` attribute. `0/1` (``Programme/Clump/single``) when absent.
    public var clump: Clump {
        get { details.fields.clump } set { details.update { $0.clump = newValue } }
    }
}

extension Programme {
    /// The less common fields, and the copy-on-write box that holds them.
    struct Details: Sendable, Hashable {
        struct Fields: Sendable, Hashable {
            var keywords: [LocalizedText] = []
            var language: LocalizedText?
            var originalLanguage: LocalizedText?
            var length: Duration?
            var urls: [URLReference] = []
            var countries: [LocalizedText] = []
            var video: Video?
            var audio: Audio?
            var premiere: LocalizedText?
            var lastChance: LocalizedText?
            var isNew = false
            var subtitles: [Subtitles] = []
            var reviews: [Review] = []
            var images: [Image] = []
            var pdcStart: XMLTVTimestamp?
            var vpsStart: XMLTVTimestamp?
            var showView: String?
            var videoPlus: String?
            var clump = Clump.single

            static let empty = Fields()
        }

        private final class Box: Sendable {
            let fields: Fields
            init(_ fields: Fields) { self.fields = fields }
        }

        private var box: Box?

        init() {}

        init(_ fields: Fields) {
            box = fields == .empty ? nil : Box(fields)
        }

        var fields: Fields { box?.fields ?? .empty }

        /// Writes go through a fresh box. The box is immutable, which makes it trivially
        /// `Sendable`, and these setters are not on any hot path. The decoder builds `Fields`
        /// once per programme.
        mutating func update(_ change: (inout Fields) -> Void) {
            var fields = self.fields
            change(&fields)
            self = Details(fields)
        }

        static func == (lhs: Details, rhs: Details) -> Bool {
            lhs.box === rhs.box || lhs.fields == rhs.fields
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(fields)
        }
    }
}
