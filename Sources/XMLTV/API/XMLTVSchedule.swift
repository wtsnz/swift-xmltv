import Foundation

/// Programmes grouped by channel and sorted by start time, with the end of each one, for "on
/// now" and "up next".
///
/// ```swift
/// let guide = try XMLTVDocument(contentsOf: url)
/// let schedule = XMLTVSchedule(guide)
/// for channelID in schedule.channelIDs {
///     let name = schedule.channel(channelID)?.displayName ?? channelID
///     let now = schedule.current(channelID, at: .now)
///     let next = schedule.next(channelID, after: .now)
///     print(name, now?.programme.title ?? "-", next?.programme.title ?? "-")
/// }
/// ```
///
/// The parser reports what the feed says. The schedule adds the rules that a guide screen
/// needs, and that apps would otherwise each write slightly differently:
///
/// - **Order.** Feeds are usually sorted, but not always. Entries are sorted by start instant,
///   and programmes that start together keep their document order.
/// - **Missing stop times.** XMLTV lets a programme leave out `stop`, meaning it runs until the
///   next one. A programme without a `stop` ends when the next programme on its channel with a
///   later start begins. The last programme on a channel without a `stop` has no known end, so
///   it is never on air.
/// - **Exact duplicates.** Merged feeds repeat records. A programme equal in every field to an
///   earlier one on the same channel at the same start is left out, so it is not listed twice.
///
/// Overlapping programmes and the members of a clump are all kept, so ``onAir(_:at:)`` returns
/// an array. ``current(_:at:)`` picks the one that started most recently, which is what a
/// "now" line should show, and of several that started together, the first in the feed, the
/// same one ``next(_:after:)`` announced. Gaps are left as gaps. A programme whose `stop` is not
/// after its `start` is kept in the list, but is never on air and never next.
///
/// A ``XMLTVOptions/timeWindow`` and inferred stop times do not mix. A window drops the
/// programme that starts after it, which is the one that says when the last programme inside
/// it ends. For a feed without stop times, parse whole channels with
/// ``XMLTVOptions/channelIDs`` and ask the schedule about the times you want.
///
/// Building a schedule copies the programmes and sorts them: 15–20 ms for 82,000 programmes on
/// an Apple M4 Max, about an eighth of the time it takes to parse them on one thread. Build it once
/// per document, off the main actor for large guides.
public struct XMLTVSchedule: Sendable {
    /// One programme in a schedule, with its end and an identity for SwiftUI.
    ///
    /// The schedule sets every property, and the ``id`` depends on them, so they are read-only.
    /// The initializer is for previews and tests.
    public struct Entry: Sendable, Hashable, Identifiable {
        /// An entry's identity: its channel, its start, and its position among the channel's
        /// entries with that start.
        ///
        /// The same programme gets the same ID in a schedule built from a later parse of the
        /// feed, as long as the programmes that share its channel and start are the same and in
        /// the same order, so SwiftUI keeps selection and row state across a refresh. IDs are
        /// `Codable`, to restore a selection. Feeds give broadcasts no identity of their own, so
        /// for a reminder, also store what the ID pointed to and check it when you look it up.
        ///
        /// The encoded form, an object with `channelID`, `secondsSince1970` and `ordinal`, is
        /// part of the stable API, so stored IDs stay readable.
        public struct ID: Sendable, Hashable, Codable {
            /// The channel's ID.
            public var channelID: String
            /// The start instant, in seconds since 1970.
            public var secondsSince1970: Int64
            /// The position among the channel's entries that start at the same instant, from 0.
            /// Usually 0; higher for the members of a clump and for overlapping records.
            public var ordinal: Int

            public init(channelID: String, secondsSince1970: Int64, ordinal: Int = 0) {
                self.channelID = channelID
                self.secondsSince1970 = secondsSince1970
                self.ordinal = ordinal
            }
        }

        /// The programme, as parsed.
        public internal(set) var programme: Programme
        /// When the programme ends: its `stop`, or without one, the start of the next programme
        /// on the channel that starts later. Nil for a final programme with no `stop`.
        public internal(set) var end: XMLTVTimestamp?
        /// The programme's position in the sequence the schedule was built from: its index in
        /// ``XMLTVDocument/programmes``. Use it to get back to the document, not as an identity:
        /// it changes whenever an earlier programme is added or removed.
        public internal(set) var index: Int
        /// The entry's position among the channel's entries with the same start. See ``ID``.
        public internal(set) var ordinal: Int

        public init(programme: Programme, end: XMLTVTimestamp?, index: Int = 0, ordinal: Int = 0) {
            self.programme = programme
            self.end = end
            self.index = index
            self.ordinal = ordinal
        }

        public var id: ID {
            ID(channelID: programme.channelID, secondsSince1970: programme.start.secondsSince1970, ordinal: ordinal)
        }

        /// Entries are equal when they show the same thing: the same programme, end and
        /// ordinal. ``index`` is left out, so the same programme from a refresh of the feed is an
        /// equal entry even if its position in the document moved.
        public static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.ordinal == rhs.ordinal && lhs.end == rhs.end && lhs.programme == rhs.programme
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(programme)
            hasher.combine(end)
            hasher.combine(ordinal)
        }

        /// When the programme starts.
        public var start: XMLTVTimestamp { programme.start }

        /// Whether ``end`` comes from the next programme rather than from the feed.
        public var isEndInferred: Bool { programme.stop == nil && end != nil }

        /// The start and end as dates. Nil when the end is unknown, or before the start.
        ///
        /// A programme covers `start ..< end`, but `DateInterval.contains(_:)` includes its
        /// end, so at the moment one programme hands over to the next, both intervals contain
        /// the date. To test whether a programme is on air, use ``isOnAir(at:)``.
        public var dateInterval: DateInterval? {
            guard let end, end.secondsSince1970 >= start.secondsSince1970 else { return nil }
            return DateInterval(start: start.date, end: end.date)
        }

        /// Whether the programme is on air at `date`: `start <= date < end`. False when the end
        /// is unknown.
        public func isOnAir(at date: Date) -> Bool {
            guard let end else { return false }
            let seconds = Self.seconds(date)
            return start.secondsSince1970 <= seconds && seconds < end.secondsSince1970
        }

        /// A date as whole seconds, rounded towards the past, the resolution of XMLTV times.
        static func seconds(_ date: Date) -> Int64 {
            XMLTVTimestamp.seconds(date, rounding: .down)
        }
    }

    /// One channel's entries, sorted, with what is needed to search them.
    private struct Timeline: Sendable {
        var entries: [Entry] = []
        /// `latestEnd[i]` is the latest end among `entries[...i]`, in seconds, or `Int64.min`
        /// when none of them has an end. Searching backwards for programmes on air can stop as
        /// soon as this is not after the date.
        var latestEnd: [Int64] = []
    }

    private var timelines: [String: Timeline]
    private var channels: [String: Channel]

    /// Every channel, each once: those the document declares, in the order it declares them,
    /// whether or not they have programmes, then channels with programmes that the document does
    /// not declare, in the order their programmes appear.
    ///
    /// A declared channel with no programmes is listed, so that a guide screen shows it, empty,
    /// rather than silently leaving it out; feeds often declare more channels than they list
    /// programmes for. Its subscript is empty, and ``current(_:at:)`` and ``next(_:after:)``
    /// return nil. Filter on `!schedule[channelID].isEmpty` to hide such channels.
    public private(set) var channelIDs: [String]

    /// Builds the schedule for a document's programmes and channels.
    public init(_ document: XMLTVDocument) {
        self.init(programmes: document.programmes, channels: document.channels)
    }

    /// Builds a schedule from programmes in any order. An entry's ``Entry/index`` is the
    /// programme's position in `programmes`.
    public init(programmes: some Sequence<Programme>) {
        self.init(programmes: Array(programmes), channels: [])
    }

    /// The channel record for an ID: the first, when the document declares it more than once.
    /// Nil for a channel that is not declared, and for every channel in a schedule built from
    /// programmes alone.
    public func channel(_ channelID: String) -> Channel? {
        channels[channelID]
    }

    private init(programmes: [Programme], channels declared: [Channel]) {
        var channels: [String: Channel] = [:]
        channels.reserveCapacity(declared.count)
        for channel in declared where channels[channel.id] == nil { channels[channel.id] = channel }
        self.channels = channels
        // Group positions rather than programmes, so sorting moves integers. Feeds are usually
        // grouped by channel already, so the previous channel is checked before the dictionary.
        var bucketOfChannel: [String: Int] = [:]
        var buckets: [[Int]] = []
        var order: [String] = []
        var lastChannel: String?, lastBucket = 0
        for (index, programme) in programmes.enumerated() {
            if programme.channelID != lastChannel {
                if let bucket = bucketOfChannel[programme.channelID] {
                    lastBucket = bucket
                } else {
                    lastBucket = buckets.count
                    bucketOfChannel[programme.channelID] = lastBucket
                    buckets.append([])
                    order.append(programme.channelID)
                }
                lastChannel = programme.channelID
            }
            buckets[lastBucket].append(index)
        }

        var timelines: [String: Timeline] = [:]
        timelines.reserveCapacity(buckets.count)
        for (channelID, var positions) in zip(order, buckets) {
            positions.sort { a, b in
                let x = programmes[a].start.secondsSince1970, y = programmes[b].start.secondsSince1970
                return x != y ? x < y : a < b
            }
            let entries = Self.entries(positions, of: programmes)
            var latestEnd: [Int64] = []
            latestEnd.reserveCapacity(entries.count)
            var latest = Int64.min
            for entry in entries {
                latest = max(latest, entry.end?.secondsSince1970 ?? .min)
                latestEnd.append(latest)
            }
            timelines[channelID] = Timeline(entries: entries, latestEnd: latestEnd)
        }
        self.timelines = timelines
        // Declared channels in declaration order, then the rest in order of appearance.
        var listed = Set<String>()
        var channelIDs = declared.compactMap { channel in
            listed.insert(channel.id).inserted ? channel.id : nil
        }
        channelIDs += order.filter { channels[$0] == nil }
        self.channelIDs = channelIDs
    }

    /// One channel's entries, from the positions of its programmes sorted by start: exact
    /// duplicates removed, ordinals assigned, and missing ends filled in.
    private static func entries(_ sorted: [Int], of programmes: [Programme]) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(sorted.count)
        var groupStart = 0   // index in `entries` of the first entry with the current start
        // Duplicates can only be among entries that start together. Groups are nearly always
        // tiny, so they are searched directly; a large one gets a set, to stay linear.
        var groupSet: Set<Programme>?
        for index in sorted {
            let programme = programmes[index]
            if let last = entries.last, last.start.secondsSince1970 == programme.start.secondsSince1970 {
                if let set = groupSet {
                    if set.contains(programme) { continue }
                } else if entries[groupStart...].contains(where: { $0.programme == programme }) {
                    continue
                }
                if groupSet == nil && entries.count - groupStart >= 16 {
                    groupSet = Set(entries[groupStart...].map(\.programme))
                }
                groupSet?.insert(programme)
                entries.append(Entry(programme: programme, end: programme.stop, index: index, ordinal: entries.count - groupStart))
            } else {
                groupStart = entries.count
                groupSet = nil
                entries.append(Entry(programme: programme, end: programme.stop, index: index))
            }
        }

        // Walk backwards, remembering the earliest start seen that is later than the current
        // one: that is when a programme without a stop ends.
        var nextStart: XMLTVTimestamp?
        var index = entries.count - 1
        while index >= 0 {
            let first = index - entries[index].ordinal
            for k in first...index where entries[k].programme.stop == nil {
                entries[k].end = nextStart
            }
            nextStart = entries[first].start
            index = first - 1
        }
        return entries
    }

    /// The channel's entries, sorted by start. Empty for a channel with no programmes.
    public subscript(channelID: String) -> [Entry] {
        timelines[channelID]?.entries ?? []
    }

    /// The programme to show as "now" on the channel: of those on air at `date`, the one that
    /// started most recently, and of several that started together, such as a clump, the first
    /// in the feed. That is the entry ``next(_:after:)`` returned before it started. Nil in a gap.
    ///
    /// When programmes overlap, the later one has usually replaced the earlier, as when a feed
    /// does not shorten a programme that a schedule change cut short.
    public func current(_ channelID: String, at date: Date) -> Entry? {
        guard let timeline = timelines[channelID] else { return nil }
        let seconds = Entry.seconds(date)
        // Backwards from the last entry that has started: the first on air is the latest start.
        var index = Self.firstStart(after: seconds, in: timeline.entries) - 1
        while index >= 0 && timeline.latestEnd[index] > seconds {
            if timeline.entries[index].isOnAir(at: date) {
                // The first of the entries on air that share this start.
                let start = timeline.entries[index].start.secondsSince1970
                var first = index, k = index - 1
                while k >= 0 && timeline.entries[k].start.secondsSince1970 == start {
                    if timeline.entries[k].isOnAir(at: date) { first = k }
                    k -= 1
                }
                return timeline.entries[first]
            }
            index -= 1
        }
        return nil
    }

    /// The channel's programmes on air at `date`, in start order. Usually one; more where the
    /// feed overlaps programmes or lists a clump; none in a gap.
    public func onAir(_ channelID: String, at date: Date) -> [Entry] {
        guard let timeline = timelines[channelID] else { return [] }
        let seconds = Entry.seconds(date)
        var index = Self.firstStart(after: seconds, in: timeline.entries) - 1
        var found: [Entry] = []
        while index >= 0 && timeline.latestEnd[index] > seconds {
            if timeline.entries[index].isOnAir(at: date) { found.append(timeline.entries[index]) }
            index -= 1
        }
        return found.reversed()
    }

    /// The channel's first programme that starts after `date`. When several start at that
    /// instant, as in a clump, this is the first of them in document order; the subscript has
    /// the rest. Programmes that end as they start are skipped, since they are never on air.
    public func next(_ channelID: String, after date: Date) -> Entry? {
        guard let timeline = timelines[channelID] else { return nil }
        var index = Self.firstStart(after: Entry.seconds(date), in: timeline.entries)
        // Skip entries that end as they start: they are never on air, so "next" would announce
        // something that never shows as "now".
        while index < timeline.entries.count, let end = timeline.entries[index].end,
              end.secondsSince1970 <= timeline.entries[index].start.secondsSince1970 {
            index += 1
        }
        return index < timeline.entries.count ? timeline.entries[index] : nil
    }

    /// The index of the first entry that starts after `seconds`.
    private static func firstStart(after seconds: Int64, in entries: [Entry]) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].start.secondsSince1970 <= seconds { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
