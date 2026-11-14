# Getting started

Add the package, parse a guide, and find the programmes you want.

## Overview

### Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/wtsnz/swift-xmltv.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "XMLTV", package: "swift-xmltv"),
    ]),
]
```

The package is `swift-xmltv`, and the module you import is `XMLTV`.

The library needs Swift 6.2 or later and runs on macOS 15, iOS 18, tvOS 18, watchOS 11 and
visionOS 2 or later. Its only dependency is the system zlib.

### Parse a guide

``XMLTVDocument`` reads a file or `Data`, compressed or not, and returns every channel and
programme in document order.

```swift
import XMLTV

let guide = try XMLTVDocument(contentsOf: URL(filePath: "guide.xml.gz"))

print(guide.info.generatorInfoName ?? "unknown generator")
print(guide.channels.count, "channels,", guide.programmes.count, "programmes")
```

Gzip is detected from the first bytes, not the file name. The encoding comes from the byte-order
mark or the XML declaration. See <doc:FormatSupport>.

### Work with programmes

A ``Programme`` covers the half-open interval `start ..< stop` on one channel. Times are
``XMLTVTimestamp`` values. They sort by instant and convert to `Date` when you need one.

```swift
let now = Date.now
let onNow = guide.programmes.filter { programme in
    programme.start.date <= now && (programme.stop?.date ?? .distantFuture) > now
}

for programme in onNow {
    let episode = programme.episodeNumbers.lazy.compactMap(\.xmltvNS).first
    print(programme.channelID, programme.title ?? "",
          episode?.displaySeason ?? 0, episode?.displayEpisode ?? 0)
}
```

Text that the format allows in several languages, such as titles, descriptions and categories,
is an array of ``LocalizedText``. The first element is the one the source listed first.
``Programme/title`` is a shortcut for the first title.

### Read only what you need

Most apps carry a few hundred channels, and many guides list tens of thousands. Pass the channel
IDs you want, and the parser skips every other programme without decoding it.

```swift
var options = ParseOptions()
options.channelIDs = ["BBC.One.uk", "ITV1.uk"]
options.timeWindow = Date.now ..< Date.now.addingTimeInterval(24 * 3600)

let tonight = try XMLTVDocument(contentsOf: url, options: options)
```

On the 1.93 GB test feed, keeping 1 channel in 64 runs at about 15 GB/s. Decoding everything
runs at 4.4 GB/s.

### Check what happened

Every parse returns a ``ParseReport``. Real feeds have errors, and the parser recovers from
most of them. The report says what it recovered from, so you can decide whether to trust the
result.

```swift
if guide.report.isTruncated {
    print("The guide was cut off. It has", guide.programmes.count, "complete programmes.")
}
for diagnostic in guide.report.diagnostics {
    print(diagnostic)   // "line 11687628: invalidTimestamp("20261113006000+0000")"
}
```

To reject anything imperfect instead, set ``ParseOptions/policy`` to
``ParseOptions/Policy/strict``. <doc:ErrorsAndDiagnostics> covers both policies.

### Next steps

- Read a guide without holding all of it in memory: <doc:ChoosingAnEntryPoint>.
- Handle zone names such as `BST` correctly: <doc:Timestamps>.
- Tune for very large guides: <doc:Performance>.
