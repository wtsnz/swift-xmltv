extension XMLTVDecoder {
    /// Decodes a `<programme>` whose start tag was just read. Returns nil when the programme is
    /// filtered out or lacks a required attribute. The element is consumed in every case.
    mutating func decodeProgramme(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Programme? {
        // Read every attribute before the first child token replaces them.
        var channelAttribute: RawAttribute?, startAttribute: RawAttribute?, stopAttribute: RawAttribute?
        var rareAttributes: [RawAttribute] = []
        for index in 0..<scanner.attributeCount {
            let attribute = scanner.attribute(at: index)
            let attributeName = attribute.name
            if scanner.bytes(attributeName, equal: "start") { startAttribute = attribute }
            else if scanner.bytes(attributeName, equal: "stop") { stopAttribute = attribute }
            else if scanner.bytes(attributeName, equal: "channel") { channelAttribute = attribute }
            else { rareAttributes.append(attribute) }
        }

        guard let channelAttribute, let startAttribute else {
            let missing = channelAttribute == nil ? "channel" : "start"
            try diagnostics.report(.missingAttribute(element: "programme", attribute: missing), at: elementStart)
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }

        // Selection runs first, so rejected programmes cost one attribute compare and a skip.
        let (channelID, isSelected) = try channel(channelAttribute)
        guard isSelected else {
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        guard let start = try timestamp(startAttribute) else {
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }
        let stop = try stopAttribute.flatMap { attribute throws(XMLTVError) in try timestamp(attribute) }
        guard isInTimeWindow(start: start, stop: stop) else {
            try skipContent(of: name, isEmpty: isEmpty)
            return nil
        }

        var programme = Programme(channelID: channelID, start: start, stop: stop)
        var details = Programme.Details.Fields()
        var hasDetails = false
        if !rareAttributes.isEmpty {
            hasDetails = try decodeRareAttributes(rareAttributes, into: &details)
        }
        if !isEmpty {
            try decodeChildren(of: name, into: &programme, details: &details, hasDetails: &hasDetails)
        }
        if hasDetails { programme.details = Programme.Details(details) }
        if programme.titles.isEmpty {
            try diagnostics.report(.missingElement(element: "programme", child: "title"), at: elementStart)
        }
        expectedCounts.update(from: programme)
        return programme
    }

    private mutating func decodeRareAttributes(
        _ attributes: [RawAttribute], into details: inout Programme.Details.Fields
    ) throws(XMLTVError) -> Bool {
        var found = false
        for attribute in attributes {
            let name = attribute.name
            if scanner.bytes(name, equal: "pdc-start") { details.pdcStart = try timestamp(attribute); found = true }
            else if scanner.bytes(name, equal: "vps-start") { details.vpsStart = try timestamp(attribute); found = true }
            else if scanner.bytes(name, equal: "showview") { details.showView = try string(attribute); found = true }
            else if scanner.bytes(name, equal: "videoplus") { details.videoPlus = try string(attribute); found = true }
            else if scanner.bytes(name, equal: "clumpidx") {
                if let clump = try clump(attribute) { details.clump = clump; found = true }
            }
        }
        return found
    }

    private mutating func decodeChildren(
        of name: ByteRange, into programme: inout Programme,
        details: inout Programme.Details.Fields, hasDetails: inout Bool
    ) throws(XMLTVError) {
        while true {
            switch try scanner.next() {
            case .startTag(let child, let isEmpty):
                let tag = XMLTVElement(scanner.pointer(to: child))
                switch tag {
                // Common fields, stored inline in `Programme`.
                case .title:
                    append(try localizedText(child, isEmpty: isEmpty), to: &programme.titles, expecting: expectedCounts.titles)
                case .subTitle:
                    append(try localizedText(child, isEmpty: isEmpty), to: &programme.subTitles, expecting: expectedCounts.subTitles)
                case .desc:
                    append(try localizedText(child, isEmpty: isEmpty), to: &programme.descriptions, expecting: expectedCounts.descriptions)
                case .category:
                    append(try localizedText(child, isEmpty: isEmpty), to: &programme.categories, expecting: expectedCounts.categories)
                case .credits:
                    try decodeCredits(child, isEmpty: isEmpty, into: &programme.credits)
                case .date:
                    let date = try textContent(of: child, isEmpty: isEmpty)
                    if programme.date == nil { programme.date = date }
                case .episodeNum:
                    append(try episodeNumber(child, isEmpty: isEmpty), to: &programme.episodeNumbers, expecting: expectedCounts.episodeNumbers)
                case .icon:
                    if let icon = try icon(child, isEmpty: isEmpty) { append(icon, to: &programme.icons, expecting: expectedCounts.icons) }
                case .rating:
                    if let rating = try rating(child, isEmpty: isEmpty) { append(rating, to: &programme.ratings, expecting: expectedCounts.ratings) }
                case .starRating:
                    if let rating = try rating(child, isEmpty: isEmpty) {
                        programme.starRatings.append(StarRating(system: rating.system, value: rating.value, icons: rating.icons))
                    }
                case .previouslyShown:
                    programme.previouslyShown = try previouslyShown(child, isEmpty: isEmpty)

                // Less common fields, stored in `details`.
                case .keyword:
                    details.keywords.append(try localizedText(child, isEmpty: isEmpty)); hasDetails = true
                case .language:
                    details.language = try localizedText(child, isEmpty: isEmpty); hasDetails = true
                case .origLanguage:
                    details.originalLanguage = try localizedText(child, isEmpty: isEmpty); hasDetails = true
                case .length:
                    if let length = try length(child, isEmpty: isEmpty) { details.length = length; hasDetails = true }
                case .url:
                    details.urls.append(try link(child, isEmpty: isEmpty)); hasDetails = true
                case .country:
                    details.countries.append(try localizedText(child, isEmpty: isEmpty)); hasDetails = true
                case .video:
                    details.video = try video(child, isEmpty: isEmpty); hasDetails = true
                case .audio:
                    details.audio = try audio(child, isEmpty: isEmpty); hasDetails = true
                case .premiere:
                    details.premiere = try localizedText(child, isEmpty: isEmpty); hasDetails = true
                case .lastChance:
                    details.lastChance = try localizedText(child, isEmpty: isEmpty); hasDetails = true
                case .new:
                    try skipContent(of: child, isEmpty: isEmpty)
                    details.isNew = true; hasDetails = true
                case .subtitles:
                    details.subtitles.append(try subtitles(child, isEmpty: isEmpty)); hasDetails = true
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

    private mutating func decodeCredits(_ name: ByteRange, isEmpty: Bool, into credits: inout [Credit]) throws(XMLTVError) {
        guard !isEmpty else { return }
        while true {
            switch try scanner.next() {
            case .startTag(let child, let childIsEmpty):
                if let role = Credit.Role(XMLTVElement(scanner.pointer(to: child))) {
                    append(try credit(role, child, isEmpty: childIsEmpty), to: &credits, expecting: expectedCounts.credits)
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
    private mutating func credit(_ role: Credit.Role, _ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Credit {
        var credit = Credit(role: role, name: "")
        if role == .actor {
            if let character = scanner.attribute("role") { credit.character = try string(character) }
            if let guest = scanner.attribute("guest") {
                credit.isGuest = try text.withAttributeBytes(guest, in: scanner, diagnostics: &diagnostics) {
                    $0.elementsEqual("yes".utf8)
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
        _ credit: Credit, _ name: ByteRange, pieces: [TextPiece], next first: XMLToken
    ) throws(XMLTVError) -> Credit {
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
                credit.name = try text.finishPieces(at: pieces.first?.range.start ?? elementStart, diagnostics: &diagnostics)
                return credit
            case .endOfInput:
                throw scanner.truncated()
            }
            token = try scanner.next()
        }
    }

    // MARK: Small elements

    private mutating func episodeNumber(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> EpisodeNumber {
        let system = try scanner.attribute("system").map { attribute throws(XMLTVError) in try string(attribute) } ?? "onscreen"
        return EpisodeNumber(system: system, value: try textContent(of: name, isEmpty: isEmpty))
    }

    /// `<rating>` and `<star-rating>` share a shape: a `system` attribute, a required `<value>`
    /// and optional icons.
    private mutating func rating(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Rating? {
        let start = scanner.tokenStart
        let system = try scanner.attribute("system").map { attribute throws(XMLTVError) in try string(attribute) }
        var value: String?
        var icons: [Icon] = []
        // Some feeds write `<rating>12</rating>` with no `<value>`. Lenient mode recovers that text.
        var directText: (range: ByteRange, needsDecoding: Bool)?
        if !isEmpty {
            loop: while true {
                switch try scanner.next() {
                case .startTag(let child, let childIsEmpty):
                    switch XMLTVElement(scanner.pointer(to: child)) {
                    case .value: value = try textContent(of: child, isEmpty: childIsEmpty)
                    case .icon: if let icon = try icon(child, isEmpty: childIsEmpty) { icons.append(icon) }
                    default: try skipContent(of: child, isEmpty: childIsEmpty)
                    }
                case .endTag(let closing):
                    try expectEndTag(closing, matching: name)
                    break loop
                case .text(let range, let needsDecoding):
                    if directText == nil && !isWhitespace(range) { directText = (range, needsDecoding) }
                case .cdata:
                    continue
                case .endOfInput:
                    throw scanner.truncated()
                }
            }
        }
        if value == nil {
            try diagnostics.report(.missingElement(element: scanner.string(name), child: "value"), at: start)
            guard let directText else { return nil }
            value = try text.text(directText.range, needsDecoding: directText.needsDecoding, in: scanner, diagnostics: &diagnostics)
        }
        return Rating(system: system, value: value!, icons: icons)
    }

    private mutating func previouslyShown(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> PreviouslyShown {
        var shown = PreviouslyShown()
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
        guard let unitSeconds, let amount = Double(value), amount >= 0, amount * unitSeconds <= Self.maximumLength else {
            let detail = units.map { "\(value) \($0)" } ?? "missing units"
            try diagnostics.report(.invalidValue(element: "length", value: detail), at: start)
            return nil
        }
        return .seconds(amount * unitSeconds)
    }

    private mutating func video(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Video {
        var video = Video()
        try forEachChild(of: name, isEmpty: isEmpty) { decoder, tag, child, childIsEmpty throws(XMLTVError) in
            switch tag {
            case .present: video.isPresent = Self.yesNo(try decoder.textContent(of: child, isEmpty: childIsEmpty))
            case .colour: video.isColour = Self.yesNo(try decoder.textContent(of: child, isEmpty: childIsEmpty))
            case .aspect: video.aspect = try decoder.textContent(of: child, isEmpty: childIsEmpty)
            case .quality: video.quality = try decoder.textContent(of: child, isEmpty: childIsEmpty)
            default: try decoder.skipContent(of: child, isEmpty: childIsEmpty)
            }
        }
        return video
    }

    private mutating func audio(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Audio {
        var audio = Audio()
        try forEachChild(of: name, isEmpty: isEmpty) { decoder, tag, child, childIsEmpty throws(XMLTVError) in
            switch tag {
            case .present: audio.isPresent = Self.yesNo(try decoder.textContent(of: child, isEmpty: childIsEmpty))
            case .stereo: audio.stereo = try decoder.textContent(of: child, isEmpty: childIsEmpty)
            default: try decoder.skipContent(of: child, isEmpty: childIsEmpty)
            }
        }
        return audio
    }

    private mutating func subtitles(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Subtitles {
        var subtitles = Subtitles(type: try scanner.attribute("type").map { attribute throws(XMLTVError) in try string(attribute) })
        try forEachChild(of: name, isEmpty: isEmpty) { decoder, tag, child, childIsEmpty throws(XMLTVError) in
            if tag == .language {
                subtitles.language = try decoder.localizedText(child, isEmpty: childIsEmpty)
            } else {
                try decoder.skipContent(of: child, isEmpty: childIsEmpty)
            }
        }
        return subtitles
    }

    private mutating func review(_ name: ByteRange, isEmpty: Bool) throws(XMLTVError) -> Review? {
        let start = scanner.tokenStart
        var review = Review(type: "", value: "")
        for index in 0..<scanner.attributeCount {
            let attribute = scanner.attribute(at: index)
            if scanner.bytes(attribute.name, equal: "type") { review.type = try string(attribute) }
            else if scanner.bytes(attribute.name, equal: "source") { review.source = try string(attribute) }
            else if scanner.bytes(attribute.name, equal: "reviewer") { review.reviewer = try string(attribute) }
            else if scanner.bytes(attribute.name, equal: "lang") { review.language = try string(attribute) }
        }
        review.value = try textContent(of: name, isEmpty: isEmpty)
        if review.type.isEmpty {
            try diagnostics.report(.missingAttribute(element: "review", attribute: "type"), at: start)
            return nil
        }
        return review
    }

    private mutating func clump(_ attribute: RawAttribute) throws(XMLTVError) -> Clump? {
        let value = try string(attribute)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]), index >= 0, count > index {
            return Clump(index: index, count: count)
        }
        try diagnostics.report(.invalidValue(element: "clumpidx", value: value), at: attribute.value.start)
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
    @inline(__always)
    private func append<Element>(_ element: Element, to array: inout [Element], expecting count: Int) {
        if array.isEmpty && count > 1 { array.reserveCapacity(count) }
        array.append(element)
    }

    private static let maximumLength = 100 * 365 * 86_400.0

    private static func yesNo(_ text: String) -> Bool? {
        switch text {
        case "yes": true
        case "no": false
        default: nil
        }
    }
}

/// A run of text inside mixed content, decoded once the element ends.
struct TextPiece {
    var range: ByteRange
    var mode: TextDecoder.Mode
    var needsDecoding: Bool
}

extension Credit.Role {
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
    var titles = 1, subTitles = 1, descriptions = 1, categories = 1, episodeNumbers = 1
    var icons = 1, ratings = 1, credits = 1

    mutating func update(from programme: Programme) {
        titles = programme.titles.count
        subTitles = programme.subTitles.count
        descriptions = programme.descriptions.count
        categories = programme.categories.count
        episodeNumbers = programme.episodeNumbers.count
        icons = programme.icons.count
        ratings = programme.ratings.count
        credits = programme.credits.count
    }
}
