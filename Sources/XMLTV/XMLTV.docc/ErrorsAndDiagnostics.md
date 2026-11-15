# Errors and diagnostics

How the parser decides between throwing, recovering and reporting, and how to show the result
to people.

## Overview

Problems in XMLTV input fall into two kinds, and the parser treats them differently.

**Broken markup** means the XML itself is damaged: an end tag that doesn't match its start tag,
an unclosed quote, a raw `<` in an attribute value, or a root element other than `<tv>`. Once
the markup is damaged, the parser can no longer tell which text belongs to which element. Any
guess would produce data that looks valid and isn't. Broken markup therefore always throws an
``XMLTVError``, whatever the policy. Input that simply stops, even inside a tag or a quoted
value, is different: it is a cut-off download, and lenient mode keeps every record before the
cut. A streaming parse also throws, in either mode, at a single record larger than
``XMLTVOptions/maximumRecordSize``: ``XMLTVError/Kind/recordTooLarge(maximumSize:)`` is a limit
on memory, not a problem with the guide.

**Bad content** means the markup is fine but a value is wrong: a timestamp with minute 60, a
`<length>` with no units, an unknown entity, invalid UTF-8 in a title, a programme with no
`channel` attribute. Each problem is local to one value or one record, so recovering is safe.
What happens next depends on ``XMLTVOptions/policy``.

### Lenient mode, the default

``XMLTVOptions/Policy/lenient`` recovers what it can and records an ``XMLTVDiagnostic`` for
each recovery, with a line number and its ``XMLTVDiagnostic/Recovery``: what the problem cost.
The rule for each kind of problem is fixed:

| Problem | What happens | ``XMLTVDiagnostic/Recovery`` |
|---|---|---|
| Time field out of range: hour 24, minute 60, second 60 | Normalised. `20261113006000` is read as 01:00:00. | `repaired` |
| Unparseable `start` | The programme is dropped. | `programmeDropped` |
| Unparseable `stop` or other time | The value becomes nil. | `valueDropped` |
| Zone name missing from ``XMLTVOptions/namedTimeZones`` | Read as UTC, and ``XMLTVTimestamp/isTimeZoneKnown`` is false. | `assumedDefault` |
| Programme without `start`, or with no or an empty `channel` | The programme is dropped. | `programmeDropped` |
| Channel with no or an empty `id` | The channel is dropped. | `channelDropped` |
| Programme without a title, channel without a display name | Kept, with an empty array. | `keptAsWritten` |
| `<rating>12</rating>` with no `<value>` | The direct text becomes the value. | `repaired` |
| `<rating>` with neither | The rating is dropped. | `valueDropped` |
| Icon without `src`, review without `type` | The element is dropped. | `valueDropped` |
| `<present>`, `<colour>` other than `yes` or `no` | The value becomes nil. | `valueDropped` |
| `guest` other than `yes` or `no` | Read as `no`. | `assumedDefault` |
| Unknown entity such as `&nbsp;`, or a reference to a forbidden character | Kept literally. | `keptAsWritten` |
| Invalid UTF-8 | Replaced with U+FFFD. | `repaired` |
| A character XML forbids, such as NUL or U+FFFF | Kept. | `keptAsWritten` |
| Empty or unparseable `<length>`, or one without known units; unparseable `clumpidx` or icon size | The value becomes nil, or the default. | `valueDropped` |
| Content after `</tv>` | Ignored. This is usually a second document appended to the first. | `restOfInputIgnored` |
| Input ends inside the document | Every complete record is kept, and ``XMLTVReport/isTruncated`` is true. | `restOfInputIgnored` |
| Truncated gzip stream | Everything decompressed before the cut is parsed, as for a cut-off download. | `restOfInputIgnored` |
| Corrupt gzip stream | The same, but zlib usually emits some garbage before it detects the damage, and the garbage is then broken markup, which throws. | `restOfInputIgnored` |
| Malformed UTF-16 | Replaced with U+FFFD. | `repaired` |

The defaults come from the feeds this library was tested against. The 1.93 GB benchmark feed
alone has 571 stop times with minute 60, 1,089 `<rating>` elements with text but no `<value>`,
1,089 empty `<length units="minutes" />` elements, and 1,922 fractional lengths such as `2.5`
hours. Rejecting the whole file over any of these would help nobody.

### Summarising a parse

``XMLTVReport/diagnostics`` holds the first ``XMLTVOptions/diagnosticLimit`` diagnostics, 100
by default, in document order. In a large feed those often come from one stretch of the file,
so use the counts, which cover the whole document, for anything you show:

- ``XMLTVReport/droppedProgrammeCount`` and ``XMLTVReport/droppedChannelCount``: records that
  were lost. Programmes on channels that ``XMLTVOptions/channelIDs`` excludes are skipped before
  they are checked, so they never count.
- ``XMLTVReport/diagnosticCountsByCode``: how many of each ``XMLTVError/Code``.
- ``XMLTVReport/diagnosticCount``: the total.
- ``XMLTVReport/isTruncated``: whether the input ended early. Records after the cut are not
  counted, because nothing is known about them.

```swift
let report = guide.report
var problems: [String] = []
if report.isTruncated { problems.append("The guide was cut off.") }
if report.droppedProgrammeCount > 0 { problems.append("\(report.droppedProgrammeCount) programmes could not be read.") }
for (code, count) in report.diagnosticCountsByCode.sorted(by: { $0.value > $1.value }) {
    logger.info("\(code.rawValue): \(count)")
}
```

### Showing errors and diagnostics

``XMLTVError`` conforms to `LocalizedError`, so `localizedDescription` is a sentence, such as
"The guide is not well-formed XML: found </desc> where </title> was expected. (line 12, column
40)". ``XMLTVDiagnostic/message`` is the same for a diagnostic, with what was done about it:
"Line 12: The time “2024-01-01T12:00” is not valid. The programme was skipped." The text is in
English. To localise it, switch over ``XMLTVError/Kind`` and write your own.

`description` on both types gives the raw kind and location, for logs. Do not parse it.

An HTML or JSON error page from a server, or any other input that is not XMLTV, throws
``XMLTVError/Kind/notXMLTV``.

### Strict mode

``XMLTVOptions/Policy/strict`` throws on the first problem of any kind, with the same
``XMLTVError/Kind`` a diagnostic would carry. Use it when a partial guide is worse than none,
or to check that your own generator produces none of the problems in the table above. It is not
a validator: what it does not check is listed under "What is checked, and what is not" below.

```swift
do {
    _ = try XMLTVDocument(contentsOf: url, options: XMLTVOptions(policy: .strict))
} catch {
    print(error)   // "XMLTV error at line 3, column 13: mismatchedEndTag(...)"
}
```

### Catching errors by type

The ``XMLTVDocument`` file and `Data` initializers and ``XMLTVReader`` declare
`throws(XMLTVError)`. In a `do` block that calls only them, `error` in the `catch` is an
``XMLTVError``. Once the block calls anything else that throws, or the code is in a closure
whose type is inferred, such as most `Task { }` bodies, `error` is `any Error`. Then write
`catch let error as XMLTVError`.

``XMLTVItems`` and ``XMLTVDocument/init(chunks:options:)`` use untyped `throws`, because their
source can fail with anything. Those errors pass through unchanged.

### Switching over kinds

``XMLTVError/Kind``, ``XMLTVError/Code`` and ``XMLTVDiagnostic/Recovery`` may gain cases in a
minor release, as new recovery rules are added, so a `switch` over them needs an
`@unknown default`. To count or group, use ``XMLTVError/code``, which drops the payload and can
key a dictionary.

### Damaged compressed input

Lenient reports are identical whatever path or chunk size reads the input. For damaged gzip
data in strict mode, which error is thrown first can depend on the chunking: a stream may
decode some of the garbage that inflates before the damage is detected, and throw for that,
where a whole-document parse throws ``XMLTVError/Kind/invalidCompressedData(_:)``. Either way
the parse fails.

### What is checked, and what is not

The parser checks the structure of the XML in every element, including skipped ones: tags,
quoting, matching end tags, names that start with a letter, `_` or `:`, comments without `--`
inside them, processing instructions with a target name, and a DOCTYPE and XML declaration
only before the root. Broken structure before the root means the
input is not a guide, ``XMLTVError/Kind/notXMLTV``; after the root it is
``XMLTVError/Kind/contentAfterRoot``. It is not a validating XML processor:

- It does not validate against the DTD. Children may come in any order, and unknown elements
  and attributes are skipped. Both are common in real feeds.
- Text inside skipped elements is not checked for valid UTF-8 or allowed characters, because it
  never becomes a string.
- Name characters after the first, and `]]>` in text, which XML forbids, are not checked:
  checking them would slow every element for errors no feed makes.
- Attribute names are not checked for duplicates, and repeated elements that hold one value,
  such as `<length>`, are not reported. The first occurrence is used, even when it is invalid.
- A channel ID declared more than once is not reported. ``XMLTVDocument/channels`` keeps every
  record, and ``XMLTVSchedule/channel(_:)`` returns the first. The 1.93 GB feed declares 200
  IDs twice, which is why ``Channel`` is not `Identifiable`: key a SwiftUI list of channels by
  ``XMLTVSchedule/channelIDs``, which lists each once.
- The XML declaration's version is not checked; a document that declares 1.1 is read by the
  XML 1.0 rules. Text directly inside `<tv>`, and elements in the wrong place, such as a nested
  `<tv>`, are skipped like unknown elements.

### Filtered records

Records left out by ``XMLTVOptions/channelIDs`` or ``XMLTVOptions/timeWindow`` report nothing,
whatever their problems: they are skipped before their content is decoded. The values needed
to make the choice are still read, so in strict mode a broken `channel` attribute still
throws, and with a time window, so does a start time that cannot be parsed. A channel with no
`id`, or a programme with no `channel`, can never be selected by a channel filter, so with one
it is skipped without a report too.
