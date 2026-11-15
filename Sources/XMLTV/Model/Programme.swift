import Foundation

/// A `<programme>`: one broadcast of a show on a channel, over the half-open interval
/// `start ..< stop`.
///
/// Programmes are not sorted or grouped by the parser. They keep the order of the source, which
/// is usually grouped by channel and then sorted by time, but not always. ``XMLTVSchedule``
/// groups and sorts them, and works out when programmes without a `stop` end.
///
/// The less common fields are stored out of line, which keeps this struct small. They read and
/// write like the others.
///
/// ### Identity and persistence
///
/// `Programme` is not `Identifiable`, and it will not become so. XMLTV gives a broadcast no
/// identifier, and no combination of fields is unique in real feeds: merged feeds repeat
/// records, sometimes identical in every field, and programmes in a clump share their channel
/// and times. For SwiftUI, use ``XMLTVSchedule/Entry``, which is identified by its channel,
/// start and position among programmes with the same start, or an identifier your app assigns.
///
/// `Programme` is not `Codable` either, and will not become so. To cache a guide, keep the
/// downloaded file and parse it again: that is about 20 times faster than decoding the same
/// records from JSON. The small values that apps embed in their own records, such as
/// ``XMLTVTimestamp``, ``LocalizedText``, ``EpisodeNumber`` and ``Rating``, are `Codable`;
/// <doc:DesignDecisions> lists them.
///
/// These are promises rather than omissions. If the library added either conformance later,
/// it would silently replace one an app had declared itself.
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
    /// `<sub-title>`: usually the episode title, one per language. See ``episodeTitle``.
    public var episodeTitles: [LocalizedText]
    /// Descriptions. A source may give several in one language, for example a short one and a
    /// long one.
    public var descriptions: [LocalizedText]
    /// Cast and crew in billing order.
    public var credits: [Credit]
    /// The production date, as written. XMLTV dates are often partial (`2024`, `200807`). See
    /// ``productionDate`` for the parsed value.
    public var date: String?
    /// Genres and other categories, as written.
    public var categories: [LocalizedText]
    /// Episode numbers, one per numbering system. See ``seasonEpisode`` for the season and
    /// episode, whichever system the feed uses.
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

    /// Creates a programme with the given times and title, and every other field empty. Set the
    /// others afterwards. This is mostly useful for tests and previews.
    public init(channelID: String, start: XMLTVTimestamp, stop: XMLTVTimestamp? = nil, title: String? = nil) {
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.titles = title.map { [LocalizedText($0)] } ?? []
        self.episodeTitles = []
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

    /// The first title. For a particular language, use `preferred(for:)` on
    /// ``titles``.
    public var title: String? { titles.first?.value }

    /// The first episode title.
    public var episodeTitle: String? { episodeTitles.first?.value }

    /// The scheduled running time, if both ends are known. Nil when `stop` is before `start`.
    public var duration: Duration? {
        guard let stop, stop.secondsSince1970 >= start.secondsSince1970 else { return nil }
        // `Duration` has room for the difference of any two `Int64` second counts.
        return .seconds(stop.secondsSince1970) - .seconds(start.secondsSince1970)
    }

    /// The start and stop as dates, or nil without a `stop`, or when `stop` is before `start`.
    /// ``XMLTVSchedule`` can fill in a missing `stop` from the next programme.
    ///
    /// The programme covers `start ..< stop`, but `DateInterval.contains(_:)` includes its end,
    /// so at a handover both programmes' intervals contain the date. To test what is on air,
    /// use ``XMLTVSchedule/Entry/isOnAir(at:)``.
    public var dateInterval: DateInterval? {
        guard let stop, stop.secondsSince1970 >= start.secondsSince1970 else { return nil }
        return DateInterval(start: start.date, end: stop.date)
    }

    /// ``date`` parsed, keeping its precision: `2024` is a timestamp of ``XMLTVTimestamp/Precision/year``
    /// precision, not midnight on 1 January. Nil when there is no date or it does not parse.
    public var productionDate: XMLTVTimestamp? {
        date.flatMap { try? XMLTVTimestamp($0, policy: .lenient) }
    }

    /// The credits in one role, in billing order.
    ///
    /// ```swift
    /// let cast = programme.credits(.actor).map(\.name)
    /// ```
    public func credits(_ role: Credit.Role) -> [Credit] {
        credits.filter { $0.role == role }
    }

    /// The season and episode, from the first episode number that gives them. `xmltv_ns`
    /// numbers are tried before `onscreen` ones, because they are machine-readable. Both are
    /// converted to count from one, as people do.
    public var seasonEpisode: SeasonEpisode? {
        for number in episodeNumbers where number.system == "xmltv_ns" {
            if let value = number.seasonEpisode { return value }
        }
        for number in episodeNumbers where number.system == "onscreen" {
            if let value = number.seasonEpisode { return value }
        }
        return nil
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
    /// `<subtitles>`: the ways the programme is subtitled or signed. Not to be confused with
    /// ``episodeTitles``.
    public var subtitleTracks: [SubtitleTrack] {
        get { details.fields.subtitleTracks } set { details.update { $0.subtitleTracks = newValue } }
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
            var subtitleTracks: [SubtitleTrack] = []
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
