import Foundation

// Value types that only appear inside a programme. They are nested in `Programme` so that
// generic names such as `Image` and `Rating` do not clash with SwiftUI or an app's own types.
extension Programme {
    /// One person in a programme's `<credits>`.
    public struct Credit: Sendable, Hashable {
        /// The part a person plays in making the programme. Credits keep the order of the source,
        /// which XMLTV defines as billing order.
        ///
        /// The raw value is the element name, such as `"director"`. New roles may be added in a
        /// minor release, as the DTD has added them before, so a `switch` needs `@unknown default`.
        @nonexhaustive
        public enum Role: String, Sendable, Hashable, CaseIterable {
            case director, actor, writer, adapter, producer, composer, editor, presenter, commentator, guest
        }

        /// What the person did.
        public var role: Role
        /// The person's name: the element's own text, trimmed. Text of nested `<image>` and `<url>`
        /// elements is not part of the name.
        public var name: String
        /// For actors, the character played, from the `role` attribute.
        public var character: String?
        /// For actors, whether this is a guest appearance (`guest="yes"`).
        public var isGuest: Bool
        /// Photos of the person.
        public var images: [Image]
        /// Pages about the person, such as a profile in a film database.
        public var urls: [URLReference]

        public init(_ name: String, role: Role, character: String? = nil, isGuest: Bool = false, images: [Image] = [], urls: [URLReference] = []) {
            self.role = role
            self.name = name
            self.character = character
            self.isGuest = isGuest
            self.images = images
            self.urls = urls
        }
    }

    /// A `<rating>`: a classification such as `<rating system="MPAA"><value>PG</value></rating>`.
    public struct Rating: Sendable, Hashable {
        /// The rating scheme, such as `MPAA`, `VCHIP` or a country code.
        public var system: String?
        /// The classification, as written.
        public var value: String
        /// Images for the classification, such as a badge.
        public var icons: [Icon]

        public init(_ value: String, system: String? = nil, icons: [Icon] = []) {
            self.system = system
            self.value = value
            self.icons = icons
        }
    }

    /// A `<star-rating>`: a score such as `3/5` or `3.5 / 5`.
    public struct StarRating: Sendable, Hashable {
        /// Who gave the score, when the source says.
        public var system: String?
        /// A score as numbers: `stars` out of `maximum`.
        public struct Score: Sendable, Hashable {
            /// The stars given, such as `3.5`.
            public var stars: Double
            /// The best possible score, such as `5`. Always greater than zero.
            public var maximum: Double

            public init(stars: Double, maximum: Double) {
                self.stars = stars
                self.maximum = maximum
            }

            /// The score as a fraction of the maximum, from 0 to 1.
            public var fraction: Double { stars / maximum }
        }

        /// The score exactly as written. See ``score`` for the numbers.
        public var value: String
        /// Images for the score, such as rows of stars.
        public var icons: [Icon]

        public init(_ value: String, system: String? = nil, icons: [Icon] = []) {
            self.system = system
            self.value = value
            self.icons = icons
        }

        /// The parsed `stars / maximum`, or nil when the value does not have that form.
        public var score: Score? {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let stars = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let maximum = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  stars.isFinite, maximum.isFinite, maximum > 0, stars >= 0, stars <= maximum
            else { return nil }
            return Score(stars: stars, maximum: maximum)
        }
    }

    /// A `<review>`: either the text of a review or a URL to one.
    public struct Review: Sendable, Hashable {
        /// `text` when ``value`` is the review, `url` when it is a link to the review.
        public var type: String
        /// The review text or URL, according to ``type``.
        public var value: String
        /// The publication or site the review comes from.
        public var source: String?
        /// The person who wrote the review.
        public var reviewer: String?
        /// The `lang` attribute of the review.
        public var language: String?

        public init(_ value: String, type: String, source: String? = nil, reviewer: String? = nil, language: String? = nil) {
            self.type = type
            self.value = value
            self.source = source
            self.reviewer = reviewer
            self.language = language
        }
    }

    /// `<video>` details. Each field is nil when the source does not say.
    public struct Video: Sendable, Hashable {
        /// `<present>`: false for programmes with no picture, such as radio.
        public var isPresent: Bool?
        /// `<colour>`: false for black-and-white programmes.
        public var isColour: Bool?
        /// `<aspect>`: the aspect ratio, such as `16:9`.
        public var aspect: String?
        /// `<quality>`: the picture format, such as `HDTV` or `800x600`.
        public var quality: String?

        public init(isPresent: Bool? = nil, isColour: Bool? = nil, aspect: String? = nil, quality: String? = nil) {
            self.isPresent = isPresent
            self.isColour = isColour
            self.aspect = aspect
            self.quality = quality
        }
    }

    /// `<audio>` details. Each field is nil when the source does not say.
    public struct Audio: Sendable, Hashable {
        /// `<present>`: false for programmes with no sound.
        public var isPresent: Bool?
        /// `<stereo>`: `mono`, `stereo`, `dolby`, `dolby digital`, `bilingual` or `surround`.
        public var stereo: String?

        public init(isPresent: Bool? = nil, stereo: String? = nil) {
            self.isPresent = isPresent
            self.stereo = stereo
        }
    }

    /// A `<subtitles>` element: one way the programme is subtitled or signed. Not to be confused
    /// with ``Programme/episodeTitles``, which holds `<sub-title>`.
    public struct SubtitleTrack: Sendable, Hashable {
        /// How the subtitles are delivered: `teletext`, `onscreen` or `deaf-signed`.
        public var type: String?
        /// The subtitle language.
        public var language: LocalizedText?

        public init(type: String? = nil, language: LocalizedText? = nil) {
            self.type = type
            self.language = language
        }
    }

    /// `<previously-shown>`: the programme is a repeat. Either field may be absent.
    public struct PreviouslyShown: Sendable, Hashable {
        /// When the programme was first shown.
        public var start: XMLTVTimestamp?
        /// Where the programme was first shown.
        public var channelID: String?

        public init(start: XMLTVTimestamp? = nil, channelID: String? = nil) {
            self.start = start
            self.channelID = channelID
        }
    }

    /// The `clumpidx` attribute: the position of a programme among several that share one time slot.
    ///
    /// Some sources can't say where one item ends and the next begins, as with "News; Weather" in a
    /// single 30-minute slot. They list each item as its own programme with the same times, and
    /// number them `0/2` and `1/2`.
    public struct Clump: Sendable, Hashable {
        /// The zero-based position within the clump.
        public var index: Int
        /// The number of programmes in the clump.
        public var count: Int

        /// `0/1`: a programme that has its slot to itself. The value when `clumpidx` is absent.
        public static let single = Clump(index: 0, count: 1)

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }
    }

    /// An `<image>`: a poster, backdrop or photo.
    ///
    /// The classification attributes keep the text written in the source, so values the DTD
    /// doesn't list survive.
    ///
    /// Inside an `extension Programme`, the bare name `Image` means this type rather than
    /// SwiftUI's. Write `SwiftUI.Image` there.
    public struct Image: Sendable, Hashable, Codable {
        /// The image URL as written. See ``url`` for a `URL`.
        public var urlString: String
        /// The `type` attribute: `poster`, `backdrop`, `still`, `person` or `character`.
        public var type: String?
        /// The `size` attribute: `1` (small), `2` (medium) or `3` (large).
        public var size: String?
        /// The `orient` attribute: `P` (portrait) or `L` (landscape).
        public var orientation: String?
        /// The `system` attribute, naming the source of the image.
        public var system: String?

        public init(_ urlString: String, type: String? = nil, size: String? = nil, orientation: String? = nil, system: String? = nil) {
            self.urlString = urlString
            self.type = type
            self.size = size
            self.orientation = orientation
            self.system = system
        }

        /// The image URL, as `URL(string:)` reads ``urlString``. That percent-encodes most text
        /// rather than rejecting it, so a non-nil result is not proof of a usable address.
        public var url: URL? { URL(string: urlString) }
    }
}
