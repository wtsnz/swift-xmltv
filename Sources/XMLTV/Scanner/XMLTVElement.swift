#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Every element name in the XMLTV DTD, plus `.unknown` for extensions.
enum XMLTVElement: UInt8 {
    case tv, channel, displayName, icon, url, programme
    case title, subTitle, desc, credits, date, category, keyword, language, origLanguage
    case length, country, episodeNum, video, audio, previouslyShown, premiere, lastChance
    case new, subtitles, rating, starRating, review, image
    case director, actor, writer, adapter, producer, composer, editor, presenter, commentator, guest
    case present, colour, aspect, quality, stereo, value
    case unknown

    /// Classifies an element name by length, then first byte, then an exact comparison.
    ///
    /// No name is longer than 16 bytes, so each comparison is a constant-size `memcmp` that the
    /// compiler expands into one or two word compares.
    @inline(__always)
    init(_ name: UnsafeBufferPointer<UInt8>) {
        let p = name.baseAddress!
        @inline(__always) func matches(_ literal: StaticString) -> Bool {
            memcmp(p, literal.utf8Start, literal.utf8CodeUnitCount) == 0
        }

        switch name.count {
        case 2:
            self = matches("tv") ? .tv : .unknown
        case 3:
            self = matches("url") ? .url : matches("new") ? .new : .unknown
        case 4:
            switch p[0] {
            case UInt8(ascii: "d"):
                self = matches("desc") ? .desc : matches("date") ? .date : .unknown
            case UInt8(ascii: "i"):
                self = matches("icon") ? .icon : .unknown
            default:
                self = .unknown
            }
        case 5:
            switch p[0] {
            case UInt8(ascii: "t"): self = matches("title") ? .title : .unknown
            case UInt8(ascii: "a"): self = matches("actor") ? .actor : matches("audio") ? .audio : .unknown
            case UInt8(ascii: "g"): self = matches("guest") ? .guest : .unknown
            case UInt8(ascii: "v"): self = matches("video") ? .video : matches("value") ? .value : .unknown
            case UInt8(ascii: "i"): self = matches("image") ? .image : .unknown
            default: self = .unknown
            }
        case 6:
            switch p[0] {
            case UInt8(ascii: "r"): self = matches("rating") ? .rating : matches("review") ? .review : .unknown
            case UInt8(ascii: "w"): self = matches("writer") ? .writer : .unknown
            case UInt8(ascii: "e"): self = matches("editor") ? .editor : .unknown
            case UInt8(ascii: "l"): self = matches("length") ? .length : .unknown
            case UInt8(ascii: "c"): self = matches("colour") ? .colour : .unknown
            case UInt8(ascii: "a"): self = matches("aspect") ? .aspect : .unknown
            case UInt8(ascii: "s"): self = matches("stereo") ? .stereo : .unknown
            default: self = .unknown
            }
        case 7:
            switch p[0] {
            case UInt8(ascii: "c"):
                self = matches("channel") ? .channel : matches("credits") ? .credits
                    : matches("country") ? .country : .unknown
            case UInt8(ascii: "a"): self = matches("adapter") ? .adapter : .unknown
            case UInt8(ascii: "p"): self = matches("present") ? .present : .unknown
            case UInt8(ascii: "q"): self = matches("quality") ? .quality : .unknown
            case UInt8(ascii: "k"): self = matches("keyword") ? .keyword : .unknown
            default: self = .unknown
            }
        case 8:
            switch p[0] {
            case UInt8(ascii: "c"): self = matches("category") ? .category : matches("composer") ? .composer : .unknown
            case UInt8(ascii: "d"): self = matches("director") ? .director : .unknown
            case UInt8(ascii: "p"): self = matches("producer") ? .producer : matches("premiere") ? .premiere : .unknown
            case UInt8(ascii: "l"): self = matches("language") ? .language : .unknown
            default: self = .unknown
            }
        case 9:
            switch p[0] {
            case UInt8(ascii: "p"): self = matches("programme") ? .programme : matches("presenter") ? .presenter : .unknown
            case UInt8(ascii: "s"): self = matches("sub-title") ? .subTitle : matches("subtitles") ? .subtitles : .unknown
            default: self = .unknown
            }
        case 11:
            switch p[0] {
            case UInt8(ascii: "e"): self = matches("episode-num") ? .episodeNum : .unknown
            case UInt8(ascii: "s"): self = matches("star-rating") ? .starRating : .unknown
            case UInt8(ascii: "c"): self = matches("commentator") ? .commentator : .unknown
            case UInt8(ascii: "l"): self = matches("last-chance") ? .lastChance : .unknown
            default: self = .unknown
            }
        case 12:
            self = matches("display-name") ? .displayName : .unknown
        case 13:
            self = matches("orig-language") ? .origLanguage : .unknown
        case 16:
            self = matches("previously-shown") ? .previouslyShown : .unknown
        default:
            self = .unknown
        }
    }
}
