# Errors and diagnostics

How the parser decides between throwing, recovering and reporting.

## Overview

Problems in XMLTV input fall into two kinds, and the parser treats them differently.

**Broken markup** means the XML itself is damaged: an end tag that doesn't match its start tag,
an unclosed quote, a raw `<` in an attribute value, or a root element other than `<tv>`. Once
the markup is damaged, the parser can no longer tell which text belongs to which element. Any
guess would produce data that looks valid and isn't. Broken markup therefore always throws an
``XMLTVError``, whatever the policy.

**Bad content** means the markup is fine but a value is wrong: a timestamp with minute 60, a
`<length>` with no units, an unknown entity, invalid UTF-8 in a title, a programme with no
`channel` attribute. Each problem is local to one value or one record, so recovering is safe.
What happens next depends on ``ParseOptions/policy``.

### Lenient mode, the default

``ParseOptions/Policy/lenient`` recovers what it can and records an ``XMLTVDiagnostic`` with a
byte offset and line number for each recovery. The rule for each kind of problem is fixed:

| Problem | Recovery |
|---|---|
| Time field out of range: hour 24, minute 60, second 60 | Normalised. `20261113006000` is read as 01:00:00. |
| Unparseable timestamp | A bad `start` drops the programme. A bad `stop` becomes nil. |
| Zone name missing from ``ParseOptions/namedTimeZones`` | Read as UTC, and ``XMLTVTimestamp/isTimeZoneKnown`` is false. |
| Missing required attribute: programme `start` or `channel`, channel `id` | The record is dropped. |
| Programme without a title, channel without a display name | Kept, with an empty array. |
| `<rating>12</rating>` with no `<value>` | The direct text becomes the value. |
| Unknown entity such as `&nbsp;`, or a reference to a forbidden character | Kept literally. |
| Invalid UTF-8 | Replaced with U+FFFD. |
| A character XML forbids, such as NUL or U+FFFF | Kept. |
| Unparseable number in `<length>` or an icon size | The value becomes nil. |
| Content after `</tv>` | Ignored. This is usually a second document appended to the first. |
| Input ends inside the document | Every complete record is kept, and ``ParseReport/isTruncated`` is true. |
| Truncated or corrupt gzip stream | Everything decompressed before the damage is parsed, as for a cut-off download. |
| Malformed UTF-16 | Replaced with U+FFFD. |

The defaults come from the feeds this library was tested against. The 1.93 GB benchmark feed
alone has 571 stop times with minute 60, about 1,100 `<rating>` elements with text but no
`<value>`, and about 1,900 fractional lengths such as `2.5` hours. Rejecting the whole file over
any of these would help nobody.

Diagnostics are kept in document order. ``ParseReport/diagnostics`` holds the first
``ParseOptions/diagnosticLimit`` of them, 100 by default. ``ParseReport/diagnosticCount``
counts all of them.

### Strict mode

``ParseOptions/Policy/strict`` throws on the first problem of any kind, with the same
``XMLTVError/Kind`` a diagnostic would carry. Use it for validating your own generator's
output, or when a partial guide is worse than none.

```swift
var options = ParseOptions()
options.policy = .strict
do {
    _ = try XMLTVDocument(contentsOf: url, options: options)
} catch {
    print(error)   // "XMLTV error at line 3, column 13: mismatchedEndTag(...)"
}
```

### Errors from your own code

Typed throws, `throws(XMLTVError)`, are used wherever only the parser can fail: the
``XMLTVDocument`` initializers and ``XMLTVReader``. You can switch over
``XMLTVError/Kind`` exhaustively. ``XMLTVItems`` uses untyped `throws` instead, because its
chunk sequence can fail with anything. Those errors pass through unchanged.

### What is not checked

The parser checks well-formedness, but it is not a validating XML processor:

- It does not validate against the DTD. Children may come in any order, and unknown elements
  and attributes are skipped. Both are common in real feeds.
- Text inside skipped elements is not checked for valid UTF-8 or allowed characters, because it
  never becomes a string. Its markup is checked: start tags, quotes and matching end tags.
- Attribute names are not checked for duplicates. Lookups use the first occurrence.
