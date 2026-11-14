# Timestamps

How XMLTV writes times, and how ``XMLTVTimestamp`` keeps what was written.

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
- ``XMLTVTimestamp/utcOffsetSeconds``: the offset the source wrote, so you can show local
  broadcast time without a time zone database
- ``XMLTVTimestamp/precision``: how many fields the source gave
- ``XMLTVTimestamp/isTimeZoneKnown``: false when the zone name was not recognised

Timestamps sort by instant, and ``XMLTVTimestamp/date`` converts to `Date`.

Precision matters for the `date` element and for partial times. `2024` means "some time in
2024", not "midnight on 1 January 2024". The instant is the start of the period, and
``XMLTVTimestamp/precision`` says how wide the period is. Converting straight to `Date` would
lose that distinction.

### Zone names

XMLTV has no registry of zone names, and many abbreviations are ambiguous. `IST` is India,
Ireland and Israel. `CST` is US Central, China and Cuba. Guessing would put programmes hours
out with no sign that anything was wrong, so the parser recognises only a few names by default:
UTC, GMT, Z and BST. BST means British Summer Time, as XMLTV's own UK-centric tools use it.

Any other name produces an ``XMLTVError/Kind/unresolvedTimeZone(_:)`` diagnostic, and the time
is read as UTC with ``XMLTVTimestamp/isTimeZoneKnown`` set to false. If you know what a feed
means, say so:

```swift
var options = ParseOptions()
options.namedTimeZones["IST"] = 19_800        // India, +05:30
options.namedTimeZones["CET"] = 3_600
let guide = try XMLTVDocument(contentsOf: url, options: options)
```

Lookups try the name as written, then in upper case.

### Out-of-range fields

Some generators write the end of the 00:00 hour as `006000`, minute 60. Lenient mode computes
the instant linearly, so `20261113006000` becomes 01:00:00 on the same day, and records an
``XMLTVError/Kind/invalidTimestamp(_:)`` diagnostic. Hour 24 and second 60 are handled the same
way. Leap seconds are not modelled. Dates are checked properly: 31 February is invalid, and so
is 29 February in a non-leap year.

### How it is fast

The common form is decoded without `Calendar`, `DateFormatter` or any allocation. Two
overlapping 8-byte loads cover the 14 digits. Each load is checked and converted with three
multiply-and-shift steps, the method simdjson uses. Howard Hinnant's `days_from_civil` turns the
date into a day count. The other forms take a slower, straightforward path.
