# Changelog

## 0.1.0, unreleased

The first release.

### Reading

- `XMLTVDocument` parses whole guides on every core, from a file, `Data` or an async sequence
  of chunks.
- `XMLTVReader` reads one record at a time from a file or `Data`. It is noncopyable and
  `Sendable`.
- `XMLTVItems` decodes an async sequence of byte chunks, or of single bytes such as
  `URLSession.AsyncBytes`. Its `report` is readable after a `for try await` loop, however the
  loop ended.
- Every element and attribute in the XMLTV DTD is decoded.
- Channel and time-window filters skip programmes without decoding them.
- Input may be UTF-8, UTF-16, ISO-8859-1, ISO-8859-15 or Windows-1252, gzip-compressed or not.

### Using the data

- `XMLTVSchedule` groups programmes by channel, sorts them, drops exact duplicates, infers
  missing stop times, and answers what is current, what is on air and what is next. Its entries
  have IDs that survive a refresh of the feed, for SwiftUI.
- `XMLTVDocument.channel(id:)`, `Programme.seasonEpisode`, `Programme.credits(_:)`,
  `Array<LocalizedText>.preferred(for:)`, and a `url` on `Icon`, `Programme.Image` and
  `URLReference`.
- `XMLTVTimestamp` can be made from a `Date` or parsed from text, has a `timeZone`, an ISO 8601
  `description` and `isSameInstant(as:)`, and is `Codable` in a compact form that can gain
  fields, as are `LocalizedText`, `Icon`, `URLReference` and `Programme.Image`.

### Problems in the input

- Lenient and strict error policies. Lenient mode reports every recovery as a diagnostic,
  with what it cost: a repaired value, a dropped value, or a dropped programme or channel.
- `XMLTVReport` counts diagnostics by kind and dropped records over the whole document.
- `XMLTVError` is a `LocalizedError`, and `XMLTVDiagnostic.message` is a sentence for people.
- Enums that are expected to grow are `@nonexhaustive`.

Requires Swift 6.2.3 or later.
