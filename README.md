# swift-xmltv

A Swift library for reading [XMLTV](https://github.com/XMLTV/xmltv/blob/master/xmltv.dtd) TV
guides. It decodes every field of the format into plain `Sendable` structs, at several
gigabytes per second, and recovers from the mistakes real feeds make without hiding them.

```swift
import XMLTV

let guide = try XMLTVDocument(contentsOf: url)          // .xml or .xml.gz
for programme in guide.programmes where programme.channelID == "BBC.One.uk" {
    print(programme.start.date, programme.title ?? "")
}
```

Swift 6.2 or later. macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2. No dependencies beyond the
system zlib.

```swift
.package(url: "https://github.com/wtsnz/swift-xmltv.git", from: "0.1.0")
// then, in your target:
.product(name: "XMLTV", package: "swift-xmltv")
```

## Three ways to read

```swift
// Everything, on every core.
let guide = try XMLTVDocument(contentsOf: url)

// Only some channels. Other programmes are skipped without being decoded.
var options = ParseOptions()
options.channelIDs = ["BBC.One.uk", "ITV1.uk"]
let mine = try XMLTVDocument(contentsOf: url, options: options)

// One record at a time, in constant memory.
var reader = try XMLTVReader(contentsOf: url)
while let item = try reader.next() { … }

// From a download, as the bytes arrive.
var items = XMLTVItems(chunks: downloadChunks).makeAsyncIterator()
while let item = try await items.next() { … }
```

All three produce identical records and reports. The tests check this at every chunk size down
to one byte.

## Speed

Apple M4 Max, release build, median of 7 runs. Every figure builds the complete model.

| Feed | Size | `XMLTVDocument` | One thread | Keeping 1/64 of channels |
|---|---:|---:|---:|---:|
| epgshare01 ALL_SOURCES | 1.93 GB | 442 ms, 4.36 GB/s | 0.56 GB/s | 15.5 GB/s |
| epgshare01 US2 | 78 MB | 18.2 ms, 4.29 GB/s | 0.56 GB/s | 13.6 GB/s |
| Plex US | 15.5 MB | 4.5 ms, 3.48 GB/s | 0.59 GB/s | 8.6 GB/s |

On the 1.93 GB feed, Foundation's `XMLParser` runs at 0.05 GB/s while building fewer fields, so
this library is about 88 times faster. libxml2's SAX interface runs at 0.49 GB/s while doing
nothing but counting elements. More measurements, and what makes it fast, are in
[Performance](Sources/XMLTV/XMLTV.docc/Performance.md).

## Behaviour in brief

- **Broken markup throws.** A mismatched end tag, an unclosed quote or a root other than `<tv>`
  is fatal, in every mode and in skipped content too. Guessing past damaged markup produces data
  that looks right and isn't.
- **Bad content is recovered by default.** Minute-60 timestamps, `<rating>12</rating>` with no
  `<value>`, invalid UTF-8, missing attributes and cut-off downloads are handled by fixed rules.
  Each recovery is reported as a diagnostic with a line number. `.strict` mode throws instead.
- **Times keep what the source wrote.** An `XMLTVTimestamp` holds the instant, the written
  offset and the precision, so `2024` stays distinct from midnight on 1 January. Ambiguous zone
  names such as `IST` are never guessed.
- **Encodings and compression are automatic.** UTF-8, UTF-16, ISO-8859-1, ISO-8859-15,
  Windows-1252, and gzip, detected from the bytes.
- **Some XML features are unsupported.** DTD-declared entities, namespaces, XML 1.1 and other
  encodings are out of scope. No real feed in the test corpus uses them.

## Documentation

The DocC catalog in `Sources/XMLTV/XMLTV.docc` has the API reference and these articles:

- [Getting started](Sources/XMLTV/XMLTV.docc/GettingStarted.md)
- [Choosing an entry point](Sources/XMLTV/XMLTV.docc/ChoosingAnEntryPoint.md), covering memory,
  latency and cores
- [Errors and diagnostics](Sources/XMLTV/XMLTV.docc/ErrorsAndDiagnostics.md), with every
  recovery rule
- [Timestamps](Sources/XMLTV/XMLTV.docc/Timestamps.md) and zone names
- [Format support](Sources/XMLTV/XMLTV.docc/FormatSupport.md), listing which parts of XMLTV and
  XML are read
- [Performance](Sources/XMLTV/XMLTV.docc/Performance.md)
- [Design decisions](Sources/XMLTV/XMLTV.docc/DesignDecisions.md), with what each choice costs and
  why it was made anyway

In Xcode, choose Product › Build Documentation.

To change the library, read [ARCHITECTURE.md](ARCHITECTURE.md) first. It describes the layers
and the invariants that the tests protect.

## Testing and benchmarks

```
swift test
swift build -c release && .build/release/xmltv-bench document path/to/guide.xml
```

The suite includes:
- a differential test against an independent Foundation-based decoder
- parallel-equals-serial tests on a document built to defeat the parallel splitter
- streaming tests at every chunk size
- truncation at every third byte, and random byte mutation
- a regression test for each defect found in code review

Set `XMLTV_CORPUS` to a directory of real `.xml` feeds to run the corpus tests as well.
