# Timestamps

How XMLTV writes times, how ``XMLTVTimestamp`` keeps what was written, and how to show them.

## Overview

### The format

XMLTV times are `YYYYMMDDhhmmss` followed by an optional zone: `20240101203000 +0100`. Nearly
every real feed uses exactly that form. The format also allows:

- trailing fields left off: `2024`, `202401`, `20240101`, `2024010120`, `202401012030`
- no zone at all, which means UTC
- a zone name instead of an offset: `20020517020200 BST`
- an offset with no space before it, as 1,746 start and stop times in the 1.93 GB test feed are written

### What a timestamp stores

``XMLTVTimestamp`` is a 16-byte value with four parts:

- ``XMLTVTimestamp/secondsSince1970``: the UTC instant
- ``XMLTVTimestamp/utcOffsetSeconds``: the offset the source wrote
- ``XMLTVTimestamp/precision``: how many fields the source gave
- ``XMLTVTimestamp/isTimeZoneKnown``: false when the zone name was not recognised

``XMLTVTimestamp/date`` converts to `Date`, and `description` gives ISO 8601 in the written
offset, to the source's precision: `2024-05-17T02:02:00+01:00`, or just `2024`.

Precision matters for partial times. `2024` means "some time in 2024", not "midnight on 1
January 2024". The instant is the start of the period, and ``XMLTVTimestamp/precision`` says how
wide the period is. Converting straight to `Date` would lose that distinction. Programme start
and stop times are nearly always complete. Production dates, in a programme's `<date>`, rarely
are: ``Programme/date`` keeps the text, and ``Programme/productionDate`` parses it, keeping the
precision. ``TVInfo/creationDate`` does the same for the date of the guide itself.

### Showing times

To show a time in the viewer's zone, format its `Date`, as for any other date:

```swift
let start = programme.start.date.formatted(date: .omitted, time: .shortened)   // "9:30 PM"
```

To show it as it was broadcast, use the offset the feed wrote, which ``XMLTVTimestamp/timeZone``
gives as a `TimeZone`:

```swift
var style = Date.FormatStyle(date: .omitted, time: .shortened)
style.timeZone = programme.start.timeZone ?? .gmt
let broadcastTime = programme.start.date.formatted(style)
```

The offset is only as good as the feed. Many feeds write every time in UTC, `+0000`, and then
the broadcast time shown is UTC, not the broadcaster's local time. A fixed offset also knows
nothing about daylight saving: it is the offset at that instant, as written.

For a partial time, show only what the source gave. `description` does that, in the offset the
source wrote:

```swift
if let made = programme.productionDate {
    print("Made in", made)   // "Made in 2024", not a time on 1 January
}
```

Don't format a partial time's `date` in the viewer's zone. `2024` is stored as midnight UTC on
1 January, which is still 2023 anywhere west of Greenwich.

### Equality and ordering

Two timestamps are equal only when every field is. The same instant written with different
offsets, such as `20240101120000 +0000` and `20240101130000 +0100`, is two different values.
That keeps two parsed programmes equal only when the feed said the same thing about them. To
ask whether two times are the same moment, as in "does this programme end when the next one
starts", use ``XMLTVTimestamp/isSameInstant(as:)``, or compare their `date`s.

Ordering is by instant first, and the other fields only break ties, so sorting by
`programme.start` sorts by time.

### Making timestamps

``XMLTVTimestamp/init(_:utcOffsetSeconds:)`` makes one from a `Date`, for tests, previews and
comparisons. ``XMLTVTimestamp/init(_:policy:namedTimeZones:)`` parses XMLTV text with the
parser's own rules, which is useful for values in other places, such as an extension element:

```swift
let start = try XMLTVTimestamp("20240101203000 +0100", policy: .strict)
let lenient = try XMLTVTimestamp("20261113006000", policy: .lenient)   // minute 60, normalised
```

### Zone names

XMLTV has no registry of zone names, and many abbreviations are ambiguous. `IST` is India,
Ireland and Israel. `CST` is US Central, China and Cuba. Guessing would put programmes hours
out with no sign that anything was wrong, so the parser recognises only a few names by default:
UTC, GMT, Z and BST. BST means British Summer Time, as XMLTV's own UK-centric tools use it.

Any other name produces an ``XMLTVError/Kind/unresolvedTimeZone(_:)`` diagnostic, and the time
is read as UTC with ``XMLTVTimestamp/isTimeZoneKnown`` set to false. If you know what a feed
means, say so:

```swift
var options = XMLTVOptions()
options.namedTimeZones["IST"] = 19_800        // India, +05:30
options.namedTimeZones["CET"] = 3_600
let guide = try XMLTVDocument(contentsOf: url, options: options)
```

Lookups try the name as written, then in upper case. A name must start with a letter and have
no digit before any `+` or `-`, as `BST` and `GMT+1` do. Anything else after the digits is an
invalid time, not an unknown zone: `20240101T120000Z`, the ISO form, is rejected rather than
read as midnight in a zone called `T120000Z`.

### Out-of-range fields

Some generators write the end of the 00:00 hour as `006000`, minute 60. Lenient mode computes
the instant linearly, so `20261113006000` becomes 01:00:00 on the same day, and records an
``XMLTVError/Kind/invalidTimestamp(_:)`` diagnostic. Hour 24 and second 60 are handled the same
way. Leap seconds are not modelled. Dates are checked properly: 31 February is invalid, and so
is 29 February in a non-leap year.

Timestamps are parsed without `Calendar` or `DateFormatter`; <doc:Performance> describes how.
