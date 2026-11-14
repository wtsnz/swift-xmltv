extension Programme {
    /// An `<episode-num>` in some numbering `system`. The text is kept exactly as written. The
    /// accessors interpret the two systems the format defines.
    public struct EpisodeNumber: Sendable, Hashable {
        /// `onscreen` (the default), `xmltv_ns`, or a feed-specific system such as `dd_progid`.
        public var system: String
        /// The number exactly as written, such as `S01E05` or `0 . 4 . 0/1`.
        public var value: String

        public init(system: String = "onscreen", value: String) {
            self.system = system
            self.value = value
        }

        /// The `xmltv_ns` interpretation, `season . episode . part`. Each part is zero-based and may
        /// carry a total (`2/10`) or be empty. Nil for other systems or text that does not parse.
        public var xmltvNS: XMLTVNS? {
            system == "xmltv_ns" ? XMLTVNS(value) : nil
        }

        /// A best-effort reading of on-screen forms such as `S01E05`, `S1 E5` or `1x05`. The result is
        /// one-based, as it appears on screen.
        public var onscreen: (season: Int?, episode: Int)? {
            let upper = value.uppercased().filter { !$0.isWhitespace }
            func number<S: StringProtocol>(_ text: S) -> Int? { Int(text.prefix(while: \.isNumber)) }

            if upper.hasPrefix("S"), let e = upper.firstIndex(of: "E") {
                let season = number(upper[upper.index(after: upper.startIndex)..<e])
                guard let episode = number(upper[upper.index(after: e)...]) else { return nil }
                return (season, episode)
            }
            if upper.hasPrefix("E"), let episode = number(upper.dropFirst()) {
                return (nil, episode)
            }
            if let x = upper.firstIndex(of: "X"), let season = number(upper[..<x]),
               let episode = number(upper[upper.index(after: x)...]) {
                return (season, episode)
            }
            return nil
        }
    }
}

extension Programme.EpisodeNumber {
    /// The `xmltv_ns` numbering: `season . episode . part`, all zero-based, each optionally
    /// `index/total`. For example `2 . 9 . 0/1` is the tenth episode of the third season, in one part.
    public struct XMLTVNS: Sendable, Hashable {
        /// One part of an `xmltv_ns` number, such as `4/22`: index 4 of 22.
        public struct Component: Sendable, Hashable {
            /// Zero-based index, or nil when only a total was given (`/13`).
            public var index: Int?
            /// How many there are in total, when given.
            public var total: Int?
        }

        /// The season, counting from zero. Nil when the source left it empty.
        public var season: Component?
        /// The episode within the season, counting from zero.
        public var episode: Component?
        /// The part within a multi-part episode, counting from zero.
        public var part: Component?

        /// Parses the text, tolerating spaces and empty components. Returns nil if there are not
        /// exactly three components or a number is malformed.
        public init?(_ text: String) {
            let components = text.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3 else { return nil }
            var parsed: [Component?] = []
            for component in components {
                let trimmed = component.filter { !$0.isWhitespace }
                if trimmed.isEmpty { parsed.append(nil); continue }
                let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: false)
                guard pieces.count <= 2 else { return nil }
                let index = pieces[0].isEmpty ? nil : Int(pieces[0])
                let total = pieces.count == 2 ? Int(pieces[1]) : nil
                if !pieces[0].isEmpty && (index ?? -1) < 0 { return nil }
                if pieces.count == 2 && (total ?? -1) < 0 { return nil }
                parsed.append(Component(index: index, total: total))
            }
            season = parsed[0]
            episode = parsed[1]
            part = parsed[2]
        }

        /// One-based season, as people count.
        public var displaySeason: Int? { season?.index.flatMap(Self.oneBased) }
        /// One-based episode, as people count.
        public var displayEpisode: Int? { episode?.index.flatMap(Self.oneBased) }

        private static func oneBased(_ index: Int) -> Int? {
            let (value, overflow) = index.addingReportingOverflow(1)
            return overflow ? nil : value
        }
    }
}
