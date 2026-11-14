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
for programme in guide.programmes where programme.channelID == "BBC.One.uk" {
    print(programme.start.date, programme.title ?? "")
}
```

There are three entry points, and they produce the same values:

- ``XMLTVDocument`` reads a whole guide into memory, using every core. It is the fastest and
  the simplest.
- ``XMLTVReader`` returns one record at a time from a file or `Data`. Its memory use depends on
  the largest record, not the file.
- ``XMLTVItems`` decodes an `AsyncSequence` of byte chunks, such as a download, as the chunks
  arrive.

The parser is written for the feeds that exist, not the ones the DTD describes. Real feeds
interleave channels with programmes, write minute 60 in timestamps, put text straight inside
`<rating>`, and get cut off mid-download. By default the parser recovers from problems like
these, and every recovery is reported as an ``XMLTVDiagnostic``, so nothing is silently lost.
Broken markup still throws.

On an Apple M4 Max it reads a 1.93 GB, 2.9-million-programme feed in about 0.44 seconds. That
is about 88 times faster than Foundation's `XMLParser` building only the common fields.
<doc:Performance> explains where the speed comes from, and <doc:DesignDecisions> explains what
it costs.

## Topics

### Essentials

- <doc:GettingStarted>
- ``XMLTVDocument``
- ``ParseOptions``

### Reading incrementally

- <doc:ChoosingAnEntryPoint>
- ``XMLTVReader``
- ``XMLTVItems``
- ``XMLTVItem``

### Guide data

- ``TVInfo``
- ``Channel``
- ``Programme``
- ``LocalizedText``
- ``Credit``
- ``EpisodeNumber``
- ``XMLTVNS``
- ``Rating``
- ``StarRating``
- ``Review``
- ``Icon``
- ``Image``
- ``Link``
- ``Video``
- ``Audio``
- ``Subtitles``
- ``PreviouslyShown``
- ``Clump``

### Time

- <doc:Timestamps>
- ``XMLTVTimestamp``

### Problems in the input

- <doc:ErrorsAndDiagnostics>
- ``XMLTVError``
- ``XMLTVDiagnostic``
- ``ParseReport``

### Input formats

- <doc:FormatSupport>
- ``XMLTVEncoding``

### How it works

- <doc:Performance>
- <doc:DesignDecisions>
