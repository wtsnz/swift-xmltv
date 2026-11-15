# Getting started

Add the package, parse a guide, and show what is on now.

## Overview

### Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/wtsnz/swift-xmltv.git", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "XMLTV", package: "swift-xmltv"),
    ]),
]
```

The package is `swift-xmltv`, and the module you import is `XMLTV`. Until 1.0, a minor release
such as 0.2 may change the API, and a patch release such as 0.1.1 will not, so depend on
`.upToNextMinor`. The <doc:XMLTV#Versioning> section has the details.

The library needs Swift 6.2.3 or later and runs on macOS 15, iOS 18, tvOS 18, watchOS 11 and
visionOS 2 or later. Its only dependency is the system zlib.

### Parse a guide

``XMLTVDocument`` reads a file or `Data`, compressed or not, and returns every channel and
programme in document order.

```swift
import Foundation
import XMLTV

let guide = try XMLTVDocument(contentsOf: URL(filePath: "guide.xml.gz"))

print(guide.info.generatorInfoName ?? "unknown generator")
print(guide.channels.count, "channels,", guide.programmes.count, "programmes")
```

Gzip is detected from the first bytes, not the file name. The encoding comes from the byte-order
mark or the XML declaration. See <doc:FormatSupport>.

The initializer is synchronous and uses every core, so in an app, call it off the main actor.
To read a guide from the network, download it to a file first. <doc:ChoosingAnEntryPoint>
shows both.

### Show what is on now

A ``Programme`` covers the half-open interval `start ..< stop` on one channel, but the feed
decides what that means in practice. Programmes may be out of order, some overlap, some are
listed twice, and `stop` is optional. ``XMLTVSchedule`` sorts each channel's programmes, drops
exact duplicates, and works out when a programme without a `stop` ends: when the next one
starts.

```swift
let schedule = XMLTVSchedule(guide)
let now = Date.now

for channelID in schedule.channelIDs {
    let name = schedule.channel(channelID)?.displayName ?? channelID
    let onNow = schedule.current(channelID, at: now)
    let upNext = schedule.next(channelID, after: now)
    print(name, onNow?.programme.title ?? "-", "then", upNext?.programme.title ?? "-")
}
```

``XMLTVSchedule/channelIDs`` lists every declared channel once, in the order the feed declares
them, then channels that have programmes but no `<channel>` record. A declared channel with no
programmes is listed too, with nothing on; feeds often declare more channels than they fill, so
filter on `!schedule[channelID].isEmpty` to hide those. Some feeds declare a channel twice, so
``XMLTVSchedule/channel(_:)`` returns the first record.
``XMLTVSchedule/current(_:at:)`` is the programme that started most recently, which is right
when the feed overlaps two; ``XMLTVSchedule/onAir(_:at:)`` returns them all.

In SwiftUI, list ``XMLTVSchedule/Entry`` values. Their ``XMLTVSchedule/Entry/id`` is built from
the channel and start time, so the same programme keeps its identity when you parse a newer
copy of the feed, and selection survives a refresh. Two programmes that start together, as in
a clump, are told apart by their order, so if a newer feed swaps them, their IDs swap too. For
anything you persist, such as a reminder, store the title and times with the ID and check
them when you look it up.

### Read the details

Text that the format allows in several languages, such as titles, descriptions and categories,
is an array of ``LocalizedText`` in the order the source listed it. ``Programme/title`` is the
first title. To choose by language, use `preferred(for:)`, which defaults to
the user's preferred languages.

```swift
for entry in schedule["BBC.One.uk"].prefix(5) {
    let programme = entry.programme
    let title = programme.titles.preferred()?.value ?? "Untitled"
    let episode = programme.seasonEpisode.map { "S\($0.season ?? 0)E\($0.episode ?? 0)" } ?? ""
    let cast = programme.credits(.actor).prefix(3).map(\.name)
    let poster = programme.images.first?.url ?? programme.icons.first?.url
    print(entry.start, title, episode, cast, poster?.absoluteString ?? "")
}
```

``Programme/seasonEpisode`` reads whichever numbering the feed uses, `xmltv_ns` or `onscreen`,
and counts from one. URLs are kept as text, as `urlString`, and `url` converts on demand.

### Read only what you need

Most apps carry a few hundred channels, and many guides list tens of thousands. Pass the channel
IDs you want, and the parser skips every other programme without decoding it.

```swift
let options = XMLTVOptions(
    channelIDs: ["BBC.One.uk", "ITV1.uk"],
    timeWindow: .now ..< .now.addingTimeInterval(24 * 3600))
let tonight = try XMLTVDocument(contentsOf: url, options: options)
```

Filtering is several times faster than decoding everything. See <doc:Performance>.

A time window cuts each channel's schedule off at its end, so the last programme inside the
window has nothing after it. With feeds that give every programme a `stop`, as nearly all do,
that does not matter. For a feed that leaves stops out, filter by channel only and let the
schedule answer questions about time.

### Check what happened

Every parse returns a ``XMLTVReport``. Real feeds have errors, and the parser recovers from
most of them. The report says what it recovered from, so you can decide whether to trust the
result.

```swift
let report = guide.report
if report.isTruncated {
    print("The guide was cut off. It has", guide.programmes.count, "complete programmes.")
}
if report.droppedProgrammeCount > 0 {
    print(report.droppedProgrammeCount, "programmes could not be read.")
}
for diagnostic in report.diagnostics.prefix(10) {
    print(diagnostic.message)   // "Line 12: The time “2024-01-01T12:00” is not valid. The programme was skipped."
}
```

To reject anything imperfect instead, set ``XMLTVOptions/policy`` to
``XMLTVOptions/Policy/strict``. <doc:ErrorsAndDiagnostics> covers both policies and every
recovery rule.

### Next steps

- Read a guide from the network, or without holding all of it in memory, and use the parser
  from actors and tasks: <doc:ChoosingAnEntryPoint>.
- Show times in the viewer's zone or the broadcaster's, and handle zone names such as `BST`:
  <doc:Timestamps>.
- Tune for very large guides: <doc:Performance>.
