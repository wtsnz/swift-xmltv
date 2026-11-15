# ``XMLTV``

Read XMLTV electronic programme guides into Swift values, with every field of the format, at
several gigabytes per second.

## Overview

XMLTV is the XML format that most TV listings sources publish. A document is a `<tv>` root
holding `<channel>` records and `<programme>` records. This library reads it into plain,
`Sendable` Swift structs: ``Channel``, ``Programme`` and the values inside them.

```swift
import XMLTV

let guide = try XMLTVDocument(contentsOf: url)
let schedule = XMLTVSchedule(guide)
if let now = schedule.current("BBC.One.uk", at: .now) {
    print(now.programme.title ?? "", "until", now.end?.date.formatted() ?? "unknown")
}
```

There are three entry points, and they produce the same values:

- ``XMLTVDocument`` reads a whole guide into memory, using every core. It is the fastest and
  the simplest.
- ``XMLTVReader`` returns one record at a time from a file or `Data`. Its memory stays at a few
  tens of megabytes, however large the file.
- ``XMLTVItems`` decodes an `AsyncSequence` of bytes, such as a download, as they arrive.

``XMLTVSchedule`` then groups a guide's programmes by channel and answers "what is on now" and
"what is next", including for feeds that leave out stop times.

The parser is written for the feeds that exist, not the ones the DTD describes. Real feeds
interleave channels with programmes, write minute 60 in timestamps, put text straight inside
`<rating>`, and get cut off mid-download. By default the parser recovers from problems like
these, and every recovery is reported as an ``XMLTVDiagnostic``, so nothing is silently lost.
Broken markup still throws.

It is many times faster than Foundation's `XMLParser`, and faster on one core than libxml2 is
at counting elements. <doc:Performance> has the measurements and where the speed comes from,
and <doc:DesignDecisions> explains what it costs.

### Names

Guide data has plain names, such as ``Channel`` and ``Programme``. The parser's own types are
prefixed, such as ``XMLTVOptions`` and ``XMLTVReport``. Types that only appear inside a
programme are nested in it, such as ``Programme/Credit`` and ``Programme/Image``, so that they
don't clash with an app's own types or with SwiftUI at the top level. Inside an
`extension Programme`, though, `Image` means ``Programme/Image``; write `SwiftUI.Image` there.

If your app has its own `Channel` or `Programme`, write `XMLTV.Channel`. The library will never
declare a type named `XMLTV`, so that spelling always works.

### Versioning

The library follows semantic versioning. Until 1.0, a minor release, such as 0.2, may change
the API, and a patch release, such as 0.1.1, will not. Depend on
`.upToNextMinor(from: "0.1.0")`.

These changes are not breaking, so they can come in any minor release, before 1.0 and after.
Write code that expects them:

- New cases in ``XMLTVError/Kind``, ``XMLTVError/Code``, ``XMLTVDiagnostic/Recovery``,
  ``XMLTVEncoding``, ``Programme/Credit/Role`` and the option enums. They are
  `@nonexhaustive`, so a `switch` over them needs `@unknown default`.
- New diagnostics for input that was previously accepted silently.
- Better wording in `localizedDescription` and ``XMLTVDiagnostic/message``.

``Programme`` will not become `Identifiable` or `Codable`; its documentation explains why.

## Topics

### Essentials

- <doc:GettingStarted>
- ``XMLTVDocument``
- ``XMLTVSchedule``
- ``XMLTVOptions``

### Reading incrementally

- <doc:ChoosingAnEntryPoint>
- ``XMLTVReader``
- ``XMLTVItems``
- ``XMLTVItem``
- ``XMLTVByteChunks``

### Guide data

- ``TVInfo``
- ``Channel``
- ``Programme``
- ``Programme/Credit``
- ``Programme/EpisodeNumber``
- ``Programme/SeasonEpisode``
- ``Programme/Rating``
- ``Programme/StarRating``
- ``LocalizedText``
- ``Icon``
- ``URLReference``

### Time

- <doc:Timestamps>
- ``XMLTVTimestamp``

### Problems in the input

- <doc:ErrorsAndDiagnostics>
- ``XMLTVError``
- ``XMLTVDiagnostic``
- ``XMLTVReport``

### Input formats

- <doc:FormatSupport>
- ``XMLTVEncoding``

### How it works

- <doc:Performance>
- <doc:DesignDecisions>
