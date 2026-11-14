import Foundation

/// One person in a programme's `<credits>`.
public struct Credit: Sendable, Hashable {
    /// The part a person plays in making the programme. Credits keep the order of the source,
    /// which XMLTV defines as billing order.
    public enum Role: UInt8, Sendable, Hashable, CaseIterable {
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
    public var urls: [Link]

    public init(role: Role, name: String, character: String? = nil, isGuest: Bool = false, images: [Image] = [], urls: [Link] = []) {
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

    public init(system: String? = nil, value: String, icons: [Icon] = []) {
        self.system = system
        self.value = value
        self.icons = icons
    }
}

/// A `<star-rating>`: a score such as `3/5` or `3.5 / 5`.
public struct StarRating: Sendable, Hashable {
    /// Who gave the score, when the source says.
    public var system: String?
    /// The score exactly as written. See ``score`` for the numbers.
    public var value: String
    /// Images for the score, such as rows of stars.
    public var icons: [Icon]

    public init(system: String? = nil, value: String, icons: [Icon] = []) {
        self.system = system
        self.value = value
        self.icons = icons
    }

    /// The parsed `stars / maximum`, or nil when the value does not have that form.
    public var score: (stars: Double, maximum: Double)? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let stars = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let maximum = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              maximum > 0, stars >= 0, stars <= maximum
        else { return nil }
        return (stars, maximum)
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

    public init(type: String, value: String, source: String? = nil, reviewer: String? = nil, language: String? = nil) {
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

/// A `<subtitles>` stream.
public struct Subtitles: Sendable, Hashable {
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
