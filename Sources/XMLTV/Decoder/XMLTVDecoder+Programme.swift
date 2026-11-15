extension XMLTVDecoder {
    /// Decodes a `<programme>` whose start tag was just read. Returns nil when the programme is
    /// filtered out or lacks a required attribute. The element is consumed in every case.
    mutating func decodeProgramme(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme? {
        // Read every attribute before the first child token replaces them.
        var channelAttribute: RawAttribute?, startAttribute: RawAttribute?, stopAttribute: RawAttribute?
        var hasRareAttributes = false
        // A repeated attribute is not an error here, but only its first occurrence is used.
        for index in 0..<scanner.attributeCount {
            let attribute = scanner.attribute(at: index)
            let attributeName = attribute.name
            if scanner.bytes(attributeName, equal: "start") { if startAttribute == nil { startAttribute = attribute } }
            else if scanner.bytes(attributeName, equal: "stop") { if stopAttribute == nil { stopAttribute = attribute } }
            else if scanner.bytes(attributeName, equal: "channel") { if channelAttribute == nil { channelAttribute = attribute } }
            else { hasRareAttributes = true }
        }

        // Selection runs before validation, so a programme on a channel the caller excluded is
        // skipped at the cost of one attribute compare, and its problems are not reported. With
        // a channel filter, a programme with no channel can never be selected. An empty channel
        // can never match a declared channel, so it counts as missing.
        guard let channelAttribute, !channelAttribute.value.isEmpty else {
            if channelIDs == nil {
                try diagnostics.report(.missingAttribute(element: "programme", attribute: "channel"), .programmeDropped, at: elementStart)
            }
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        let (channelID, isSelected) = try channel(channelAttribute)
        guard isSelected else {
            // Reading the channel attribute may have reported a repair in it. The programme is
            // not wanted, so neither is that.
            diagnostics.discardPending()
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        guard let startAttribute else {
            try diagnostics.report(.missingAttribute(element: "programme", attribute: "start"), .programmeDropped, at: elementStart)
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        guard let start = try timestamp(startAttribute, ifInvalid: .programmeDropped) else {
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        let stop = try stopAttribute.flatMap { attribute throws(XMLTVError) in try timestamp(attribute) }
        guard isInTimeWindow(start: start, stop: stop) else {
            // Outside the window: like a programme on an excluded channel, it reports nothing,
            // including any repair its times needed.
            diagnostics.discardPending()
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }

        var programme = Programme(channelID: channelID, start: start, stop: stop)
        var details = Programme.Details.Fields()
        var hasDetails = false
        if hasRareAttributes {
            hasDetails = try decodeRareAttributes(into: &details)
        }
        if !isEmpty {
            try decodeChildren(of: name, into: &programme, details: &details, hasDetails: &hasDetails)
        }
        if hasDetails { programme.details = Programme.Details(details) }
        if programme.titles.isEmpty {
            try diagnostics.report(.missingElement(element: "programme", child: "title"), .keptAsWritten, at: elementStart)
        }
        expectedCounts.update(from: programme)
        return programme
    }

    /// The start tag's attributes are still current: nothing since it was read has advanced
    /// the scanner.
    private mutating func decodeRareAttributes(into details: inout Programme.Details.Fields) throws(XMLTVError) -> Bool {
        if let attribute = scanner.attribute("pdc-start") { details.pdcStart = try timestamp(attribute) }
        if let attribute = scanner.attribute("vps-start") { details.vpsStart = try timestamp(attribute) }
        details.showView = try optionalString("showview")
        details.videoPlus = try optionalString("videoplus")
        if let attribute = scanner.attribute("clumpidx"), let clump = try clump(attribute) { details.clump = clump }
        return details.pdcStart != nil || details.vpsStart != nil || details.showView != nil
            || details.videoPlus != nil || details.clump != .single
    }

    private mutating func decodeChildren(
        of name: ByteRange, into programme: inout Programme,
        details: inout Programme.Details.Fields, hasDetails: inout Bool
    ) throws(XMLTVError) {
        // An invalid `<length>` decodes as nil, and an empty `<credits/>` adds nobody, but each
        // still counts as the first of its kind.
        var hasLength = false, hasCredits = false
        while true {
            switch try scanner.next() {
            case .startTag(let child, let isEmpty):
                let tag = XMLTVElement(scanner.pointer(to: child))
                switch tag {
                // Common fields, stored inline in `Programme`.
                case .title:
                    Self.append(try localizedText(child, isEmpty: isEmpty), to: &programme.titles, expecting: expectedCounts.titles)
                case .subTitle:
                    Self.append(try localizedText(child, isEmpty: isEmpty), to: &programme.episodeTitles, expecting: expectedCounts.episodeTitles)
                case .desc:
                    Self.append(try localizedText(child, isEmpty: isEmpty), to: &programme.descriptions, expecting: expectedCounts.descriptions)
                case .category:
                    Self.append(try localizedText(child, isEmpty: isEmpty), to: &programme.categories, expecting: expectedCounts.categories)
                case .credits:
                    // `<credits>` is single-valued. A later one is decoded, so its problems are
                    // reported as for any repeated child, but its people are not kept.
                    if hasCredits {
                        var ignored: [Programme.Credit] = []
                        try decodeCredits(child, isEmpty: isEmpty, into: &ignored)
                    } else {
                        try decodeCredits(child, isEmpty: isEmpty, into: &programme.credits)
                        hasCredits = true
                    }
                case .date:
                    let date = try textContent(of: child, isEmpty: isEmpty)
                    if programme.date == nil { programme.date = date }
                case .episodeNum:
                    Self.append(try episodeNumber(child, isEmpty: isEmpty), to: &programme.episodeNumbers, expecting: expectedCounts.episodeNumbers)
                case .icon:
                    if let icon = try icon(child, isEmpty: isEmpty) { Self.append(icon, to: &programme.icons, expecting: expectedCounts.icons) }
                case .rating:
                    if let rating = try rating(child, isEmpty: isEmpty) { Self.append(rating, to: &programme.ratings, expecting: expectedCounts.ratings) }
                case .starRating:
                    if let rating = try rating(child, isEmpty: isEmpty) {
                        programme.starRatings.append(Programme.StarRating(rating.value, system: rating.system, icons: rating.icons))
                    }
                case .previouslyShown:
                    let shown = try previouslyShown(child, isEmpty: isEmpty)
                    if programme.previouslyShown == nil { programme.previouslyShown = shown }

                // Less common fields, stored in `details`.
                case .keyword:
                    details.keywords.append(try localizedText(child, isEmpty: isEmpty)); hasDetails = true
                // Single-valued children: the first one is kept, as for `<date>` and attributes.
                case .language:
                    let language = try localizedText(child, isEmpty: isEmpty)
                    if details.language == nil { details.language = language; hasDetails = true }
                case .origLanguage:
                    let language = try localizedText(child, isEmpty: isEmpty)
                    if details.originalLanguage == nil { details.originalLanguage = language; hasDetails = true }
                case .length:
                    let length = try length(child, isEmpty: isEmpty)
                    if !hasLength, let length { details.length = length; hasDetails = true }
                    hasLength = true
                case .url:
                    details.urls.append(try link(child, isEmpty: isEmpty)); hasDetails = true
                case .country:
                    details.countries.append(try localizedText(child, isEmpty: isEmpty)); hasDetails = true
                case .video:
                    let video = try video(child, isEmpty: isEmpty)
                    if details.video == nil { details.video = video; hasDetails = true }
                case .audio:
                    let audio = try audio(child, isEmpty: isEmpty)
                    if details.audio == nil { details.audio = audio; hasDetails = true }
                case .premiere:
                    let premiere = try localizedText(child, isEmpty: isEmpty)
                    if details.premiere == nil { details.premiere = premiere; hasDetails = true }
                case .lastChance:
                    let lastChance = try localizedText(child, isEmpty: isEmpty)
                    if details.lastChance == nil { details.lastChance = lastChance; hasDetails = true }
                case .new:
                    try skipContent(of: child, isEmpty: isEmpty)
                    details.isNew = true; hasDetails = true
                case .subtitles:
                    details.subtitleTracks.append(try subtitleTrack(child, isEmpty: isEmpty)); hasDetails = true
                case .review:
                    if let review = try review(child, isEmpty: isEmpty) { details.reviews.append(review); hasDetails = true }
                case .image:
                    details.images.append(try image(child, isEmpty: isEmpty)); hasDetails = true

                default:
                    try skipContent(of: child, isEmpty: isEmpty)
                }
            case .endTag(let closing):
                try expectEndTag(closing, matching: name)
                return
            case .text, .cdata:
                continue
            case .endOfInput:
                throw scanner.truncated()
            }
        }
    }

    // MARK: Credits

    private mutating func decodeCredits(_ name: ByteRange, isEmpty: Bool, into credits: inout [Programme.Credit]) throws(XMLTVError) {
        guard !isEmpty else { return }
        while true {
            switch try scanner.next() {
            case .startTag(let child, let childIsEmpty):
                if let role = Programme.Credit.Role(XMLTVElement(scanner.pointer(to: child))) {
                    Self.append(try credit(role, child, isEmpty: childIsEmpty), to: &credits, expecting: expectedCounts.credits)
                } else {
                    try skipContent(of: child, isEmpty: childIsEmpty)
                }
            case .endTag(let closing):
                try expectEndTag(closing, matching: name)
                return
            case .text, .cdata:
                continue
            case .endOfInput:
                throw scanner.truncated()
            }
        }
    }

    /// One person. The DTD makes these mixed content: the name is the element's own text, and it
    /// may be interleaved with `<image>` and `<url>` children.
    private mutating func credit(_ role: Programme.Credit.Role, _ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.Credit {
        var credit = Programme.Credit("", role: role)
        if role == .actor {
            if let character = scanner.attribute("role") { credit.character = try string(character) }
            if let guest = scanner.attribute("guest") {
                if !guest.needsDecoding && scanner.bytes(guest.value, equal: "yes") {
                    credit.isGuest = true
                } else if guest.needsDecoding || !scanner.bytes(guest.value, equal: "no") {
                    // The rare path: decode and validate the text, then compare.
                    let value = try string(guest)
                    switch value {
                    case "yes": credit.isGuest = true
                    case "no": break
                    default:
                        try diagnostics.report(.invalidValue(element: "actor", attribute: "guest", value: value), .assumedDefault, at: guest.value.start)
                    }
                }
            }
        }
        guard !isEmpty else { return credit }

        // Fast path: a single text token, then the end tag.
        let first = try scanner.next()
        if case .text(let range, let needsDecoding) = first {
            let second = try scanner.next()
            if case .endTag(let closing) = second {
                try expectEndTag(closing, matching: name)
                credit.name = try text.text(range, needsDecoding: needsDecoding, in: scanner, diagnostics: &diagnostics)
                return credit
            }
            return try mixedCredit(credit, name, pieces: [TextPiece(range: range, mode: .text, needsDecoding: needsDecoding)], next: second)
        }
        return try mixedCredit(credit, name, pieces: [], next: first)
    }

    private mutating func mixedCredit(
        _ credit: Programme.Credit, _ name: ByteRange, pieces: [TextPiece], next first: XMLToken
    ) throws(XMLTVError) -> Programme.Credit {
        var credit = credit
        // Text ranges stay valid until the parse ends, so pieces are kept as ranges and decoded
        // together at the end tag. That keeps the shared text buffer free for the children.
        var pieces = pieces
        var token = first
        while true {
            switch token {
            case .text(let range, let needsDecoding):
                pieces.append(TextPiece(range: range, mode: .text, needsDecoding: needsDecoding))
            case .cdata(let range):
                pieces.append(TextPiece(range: range, mode: .cdata, needsDecoding: false))
            case .startTag(let child, let isEmpty):
                switch XMLTVElement(scanner.pointer(to: child)) {
                case .image: credit.images.append(try image(child, isEmpty: isEmpty))
                case .url: credit.urls.append(try link(child, isEmpty: isEmpty))
                default: try skipContent(of: child, isEmpty: isEmpty)
                }
            case .endTag(let closing):
                try expectEndTag(closing, matching: name)
                text.beginPieces()
                for piece in pieces {
                    try text.appendPiece(piece.range, mode: piece.mode, needsDecoding: piece.needsDecoding, in: scanner, diagnostics: &diagnostics)
                }
                credit.name = text.finishPieces()
                return credit
            case .endOfInput:
                throw scanner.truncated()
            }
            token = try scanner.next()
        }
    }

    // MARK: Small elements

    private mutating func episodeNumber(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.EpisodeNumber {
        let system = try scanner.attribute("system").map { attribute throws(XMLTVError) in try string(attribute) } ?? "onscreen"
        return Programme.EpisodeNumber(try textContent(of: name, isEmpty: isEmpty), system: system)
    }

    /// `<rating>` and `<star-rating>` share a shape: a `system` attribute, a required `<value>`
    /// and optional icons.
    private mutating func rating(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.Rating? {
        let start = scanner.tokenStart
        let system = try scanner.attribute("system").map { attribute throws(XMLTVError) in try string(attribute) }
        var value: String?
        var icons: [Icon] = []
        // Some feeds write `<rating>12</rating>` with no `<value>`. Lenient mode recovers that
        // text: every run of it and every CDATA section, decoded together at the end, as for a
        // mixed-content credit.
        var directText: [TextPiece] = []
        if !isEmpty {
            loop: while true {
                switch try scanner.next() {
                case .startTag(let child, let childIsEmpty):
                    switch XMLTVElement(scanner.pointer(to: child)) {
                    case .value:
                        let text = try textContent(of: child, isEmpty: childIsEmpty)
                        if value == nil { value = text }
                    case .icon: if let icon = try icon(child, isEmpty: childIsEmpty) { icons.append(icon) }
                    default: try skipContent(of: child, isEmpty: childIsEmpty)
                    }
                case .endTag(let closing):
                    try expectEndTag(closing, matching: name)
                    break loop
                case .text(let range, let needsDecoding):
                    // Whitespace before any real text would be trimmed anyway. Skipping it keeps
                    // the usual `<rating>` with indented children from allocating.
                    if value == nil && (!directText.isEmpty || !isWhitespace(range)) {
                        directText.append(TextPiece(range: range, mode: .text, needsDecoding: needsDecoding))
                    }
                case .cdata(let range):
                    if value == nil { directText.append(TextPiece(range: range, mode: .cdata, needsDecoding: false)) }
                case .endOfInput:
                    throw scanner.truncated()
                }
            }
        }
        if value == nil {
            let elementName = scanner.string(name)
            guard directText.contains(where: { !isWhitespace($0.range) }) else {
                try diagnostics.report(.missingElement(element: elementName, child: "value"), .valueDropped, at: start)
                return nil
            }
            try diagnostics.report(.missingElement(element: elementName, child: "value"), .repaired, at: start)
            text.beginPieces()
            for piece in directText {
                try text.appendPiece(piece.range, mode: piece.mode, needsDecoding: piece.needsDecoding, in: scanner, diagnostics: &diagnostics)
            }
            value = text.finishPieces()
        }
        return Programme.Rating(value!, system: system, icons: icons)
    }

    private mutating func previouslyShown(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.PreviouslyShown {
        var shown = Programme.PreviouslyShown()
        if let start = scanner.attribute("start") { shown.start = try timestamp(start) }
        if let channel = scanner.attribute("channel") { shown.channelID = try string(channel) }
        try skipContent(of: name, isEmpty: isEmpty)
        return shown
    }

    private mutating func length(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Duration? {
        let start = scanner.tokenStart
        let units = try scanner.attribute("units").map { attribute throws(XMLTVError) in try string(attribute) }
        let unitSeconds: Double? = switch units {
        case "seconds": 1
        case "minutes": 60
        case "hours": 3600
        default: nil
        }
        let value = try textContent(of: name, isEmpty: isEmpty)
        // Fractional values such as `2.5` hours occur in real feeds; the DTD does not forbid them.
        // Anything beyond a century is treated as invalid, which also keeps `Duration` in range.
        // Decimal digits with at most one point: `Double(_:)` alone would also accept `0x10`,
        // `1e2` and `inf`.
        var points = 0
        let isDecimal = !value.isEmpty && value.utf8.allSatisfy { byte in
            if byte == UInt8(ascii: ".") { points += 1; return points <= 1 }
            return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
        guard let units else {
            try diagnostics.report(.missingAttribute(element: "length", attribute: "units"), .valueDropped, at: start)
            return nil
        }
        guard let unitSeconds else {
            try diagnostics.report(.invalidValue(element: "length", attribute: "units", value: units), .valueDropped, at: start)
            return nil
        }
        guard isDecimal, let amount = Double(value), amount >= 0, amount * unitSeconds <= Self.maximumLength else {
            try diagnostics.report(.invalidValue(element: "length", attribute: nil, value: value), .valueDropped, at: start)
            return nil
        }
        return .seconds(amount * unitSeconds)
    }

    // Each child of `<video>`, `<audio>` and `<subtitles>` is single-valued, so the first is
    // kept. A `seen` flag marks a yes/no child that was invalid and decoded as nil.

    private mutating func video(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.Video {
        var video = Programme.Video()
        var seenPresent = false, seenColour = false
        try forEachChild(of: name, isEmpty: isEmpty) { decoder, tag, child, childIsEmpty throws(XMLTVError) in
            switch tag {
            case .present:
                let value = try decoder.yesNo(child, isEmpty: childIsEmpty)
                if !seenPresent { video.isPresent = value; seenPresent = true }
            case .colour:
                let value = try decoder.yesNo(child, isEmpty: childIsEmpty)
                if !seenColour { video.isColour = value; seenColour = true }
            case .aspect:
                let value = try decoder.textContent(of: child, isEmpty: childIsEmpty)
                if video.aspect == nil { video.aspect = value }
            case .quality:
                let value = try decoder.textContent(of: child, isEmpty: childIsEmpty)
                if video.quality == nil { video.quality = value }
            default:
                try decoder.skipContent(of: child, isEmpty: childIsEmpty)
            }
        }
        return video
    }

    private mutating func audio(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.Audio {
        var audio = Programme.Audio()
        var seenPresent = false
        try forEachChild(of: name, isEmpty: isEmpty) { decoder, tag, child, childIsEmpty throws(XMLTVError) in
            switch tag {
            case .present:
                let value = try decoder.yesNo(child, isEmpty: childIsEmpty)
                if !seenPresent { audio.isPresent = value; seenPresent = true }
            case .stereo:
                let value = try decoder.textContent(of: child, isEmpty: childIsEmpty)
                if audio.stereo == nil { audio.stereo = value }
            default:
                try decoder.skipContent(of: child, isEmpty: childIsEmpty)
            }
        }
        return audio
    }

    private mutating func subtitleTrack(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.SubtitleTrack {
        var track = Programme.SubtitleTrack(type: try scanner.attribute("type").map { attribute throws(XMLTVError) in try string(attribute) })
        try forEachChild(of: name, isEmpty: isEmpty) { decoder, tag, child, childIsEmpty throws(XMLTVError) in
            if tag == .language {
                let language = try decoder.localizedText(child, isEmpty: childIsEmpty)
                if track.language == nil { track.language = language }
            } else {
                try decoder.skipContent(of: child, isEmpty: childIsEmpty)
            }
        }
        return track
    }

    private mutating func review(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme.Review? {
        let start = scanner.tokenStart
        var review = Programme.Review("", type: try optionalString("type") ?? "")
        review.source = try optionalString("source")
        review.reviewer = try optionalString("reviewer")
        review.language = try optionalString("lang")
        review.value = try textContent(of: name, isEmpty: isEmpty)
        if review.type.isEmpty {
            try diagnostics.report(.missingAttribute(element: "review", attribute: "type"), .valueDropped, at: start)
            return nil
        }
        return review
    }

    private mutating func clump(_ attribute: RawAttribute) throws(XMLTVError) -> Programme.Clump? {
        let value = try string(attribute)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]), index >= 0, count > index {
            return Programme.Clump(index: index, count: count)
        }
        try diagnostics.report(.invalidValue(element: "programme", attribute: "clumpidx", value: value), .valueDropped, at: attribute.value.start)
        return nil
    }

    // MARK: Helpers

    /// Calls `body` for each child element of the element whose start tag was just read, through
    /// its end tag. `body` must consume the child.
    private mutating func forEachChild(
        of name: ByteRange, isEmpty: Bool,
        _ body: (inout XMLTVDecoder, XMLTVElement, ByteRange, Bool) throws(XMLTVError) -> Void
    ) throws(XMLTVError) {
        guard !isEmpty else { return }
        while true {
            switch try scanner.next() {
            case .startTag(let child, let childIsEmpty):
                try body(&self, XMLTVElement(scanner.pointer(to: child)), child, childIsEmpty)
            case .endTag(let closing):
                try expectEndTag(closing, matching: name)
                return
            case .text, .cdata:
                continue
            case .endOfInput:
                throw scanner.truncated()
            }
        }
    }

    /// Appends to one of a programme's arrays. The first append reserves as many elements as the
    /// previous programme had: feeds are homogeneous, so this usually allocates once instead of
    /// regrowing at 1, 2, 4 elements.
    ///
    /// Static, so that an unoptimised build does not copy the decoder, and with it the string
    /// table, to call it while an argument is mutating the decoder.
    @inline(__always)
    private static func append<Element>(_ element: Element, to array: inout [Element], expecting count: Int) {
        if array.isEmpty && count > 1 { array.reserveCapacity(count) }
        array.append(element)
    }

    private static let maximumLength = 100 * 365 * 86_400.0

    /// A `yes` or `no` element such as `<present>`. Anything else is reported and dropped.
    private mutating func yesNo(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Bool? {
        let start = scanner.tokenStart
        let value = try textContent(of: name, isEmpty: isEmpty)
        switch value {
        case "yes": return true
        case "no": return false
        default:
            try diagnostics.report(.invalidValue(element: scanner.string(name), attribute: nil, value: value), .valueDropped, at: start)
            return nil
        }
    }
}

/// A run of text inside mixed content, decoded once the element ends.
struct TextPiece {
    var range: ByteRange
    var mode: TextDecoder.Mode
    var needsDecoding: Bool
}

extension Programme.Credit.Role {
    init?(_ tag: XMLTVElement) {
        switch tag {
        case .director: self = .director
        case .actor: self = .actor
        case .writer: self = .writer
        case .adapter: self = .adapter
        case .producer: self = .producer
        case .composer: self = .composer
        case .editor: self = .editor
        case .presenter: self = .presenter
        case .commentator: self = .commentator
        case .guest: self = .guest
        default: return nil
        }
    }
}

/// How many of each repeated child the previous programme had. See `append(_:to:expecting:)`.
struct ExpectedCounts {
    var titles = 1, episodeTitles = 1, descriptions = 1, categories = 1, episodeNumbers = 1
    var icons = 1, ratings = 1, credits = 1

    mutating func update(from programme: Programme) {
        titles = programme.titles.count
        episodeTitles = programme.episodeTitles.count
        descriptions = programme.descriptions.count
        categories = programme.categories.count
        episodeNumbers = programme.episodeNumbers.count
        icons = programme.icons.count
        ratings = programme.ratings.count
        credits = programme.credits.count
    }
}
