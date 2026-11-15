# Changelog

## 0.1.0, unreleased

The first release.

### Reading

- `XMLTVDocument` parses whole guides on every core, from a file, `Data` or an async sequence
  of chunks.
- `XMLTVReader` reads one record at a time from a file or `Data`, in bounded memory however
  large the file and however well it compresses. `XMLTVOptions.maximumRecordSize`, 16 MiB by
  default, limits a single record, so input built to exhaust memory throws `recordTooLarge`.
  The reader is noncopyable and `Sendable`, and once it throws, every later call throws the
  same error.
- `XMLTVItems` decodes an async sequence of byte chunks, or of single bytes such as
  `URLSession.AsyncBytes`. Its `report` is readable after a `for try await` loop, however the
  loop ended. A cancelled task gets `CancellationError`, never a guide that looks cut off.
  Decoding runs on the caller's actor, through `for try await` or `next()` alike.
- Every element and attribute in the XMLTV DTD is decoded.
- Channel and time-window filters skip programmes without decoding them. An empty window keeps
  nothing.
- `XMLTVOptions.parallelism` limits the threads that read a file as well as those that parse it.
- Input may be UTF-8, UTF-16, ISO-8859-1, ISO-8859-15 or Windows-1252, gzip-compressed or not.

### Using the data

- `XMLTVSchedule` groups programmes by channel, sorts them, drops exact duplicates, infers
  missing stop times, and answers what is current, what is on air and what is next. Of
  programmes that start together, "current" and "next" pick the same one, the first in the
  feed, and neither picks one that is never on air. It lists
  every declared channel, including those with no programmes. Its entries are read-only and
  have IDs that survive a refresh of the feed, for SwiftUI, as long as programmes that start
  together keep their order. The encoded form of an ID is stable.
- `XMLTVDocument` is `Hashable` by its info, channels and programmes, so a refresh can be
  compared with the guide it replaces, however the bytes arrived.
- Neither `Programme` nor `Channel` is `Identifiable`: feeds repeat both. Use schedule entries
  and `XMLTVSchedule.channelIDs` for lists.
- `XMLTVDocument.channel(id:)`, `Programme.seasonEpisode`, `Programme.credits(_:)`,
  `Array<LocalizedText>.preferred(for:)`, and a `url` on `Icon`, `Programme.Image` and
  `URLReference`.
- `XMLTVTimestamp` can be made from a `Date` or parsed from text, takes its offset as the `Int`
  that `TimeZone` gives, has a `timeZone`, an ISO 8601
  `description` and `isSameInstant(as:)`, and is `Codable` in a compact form that can gain
  fields. The other small values apps store are `Codable` too: `LocalizedText`, `Icon`,
  `URLReference`, `Programme.Image`, `EpisodeNumber`, `SeasonEpisode`, `Rating`, `StarRating`,
  `Clump`, `Credit.Role` and `XMLTVEncoding`. No other existing type will become
  `Codable`, so a later release will not replace a conformance an app declares.

### Problems in the input

- Lenient and strict error policies. Lenient mode reports every recovery as a diagnostic,
  with what it cost: a repaired value, a dropped value, or a dropped programme or channel.
- `XMLTVReport` counts diagnostics by kind and dropped records over the whole document.
- Repeated attributes and repeated single-valued elements, `<credits>` included, keep their
  first occurrence.
- Each problem in text is reported at its own byte, line and column.
- `XMLTVError` is a `LocalizedError`, and `XMLTVDiagnostic.message` is a sentence for people.
- Enums that are expected to grow are `@nonexhaustive`.

### Platforms

Requires Swift 6.2.3 or later. Apple platforms, and Linux, where the test suite passes and the
zlib headers must be installed; `URLSession.AsyncBytes` is Apple-only.
