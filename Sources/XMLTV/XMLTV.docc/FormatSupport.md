# Format support

Which parts of XMLTV and XML the parser reads, and which it deliberately does not.

## Overview

### XMLTV

Every element and attribute in the
[XMLTV DTD](https://github.com/XMLTV/xmltv/blob/master/xmltv.dtd) is decoded, including
credits with images and URLs, reviews, images, subtitle tracks, video and audio details, and the PDC,
VPS, ShowView and VideoPlus attributes.

The DTD's ordering rules are not enforced:

- Children of a programme may appear in any order. UK feeds put icons before display names,
  for example.
- `<channel>` records may appear between programmes, as Samsung TV Plus and Plex feeds do.
- Unknown elements and attributes are skipped, with no diagnostic. Real feeds add their own,
  such as `series-id`, `live`, `lcn`, `genre` and `programId`.

Some values come from an open set, such as image types, review types, audio modes and
episode-numbering systems. These are stored as the text written in the source, so values the DTD
doesn't list survive. Values with a fixed meaning are converted: `yes`/`no` to `Bool`, a
`<length>` to `Duration`, `clumpidx` to ``Programme/Clump``.

Text is trimmed of leading and trailing whitespace after entities are decoded. Inner
whitespace, including newlines, is kept. This matches the upstream `tv_cat` tool.

### Character encodings

The input is converted to UTF-8 before parsing. A UTF-8 file needs no conversion and is parsed
where it lies in memory.

| Encoding | How it is detected |
|---|---|
| UTF-8 | default; byte-order mark optional |
| UTF-16, little or big endian | byte-order mark, or `<?` in UTF-16 |
| ISO-8859-1 | `encoding="ISO-8859-1"` or an alias such as `latin1` |
| ISO-8859-15 | `encoding="ISO-8859-15"` |
| Windows-1252 | `encoding="windows-1252"` |

ISO-8859-1 is decoded exactly, as XML requires: byte 0x80 is U+0080. Web browsers treat that
label as Windows-1252, which maps byte 0x80 to €. If a feed declares ISO-8859-1 but was really
written in Windows-1252, set ``XMLTVOptions/encoding`` to override the declaration:

```swift
var options = XMLTVOptions()
options.encoding = .windows1252
```

With an override, the declaration is ignored entirely, so it also rescues feeds that declare an
encoding the parser doesn't know.

### Compression

Gzip input is detected by its first two bytes and decompressed with the system zlib. Several
gzip members concatenated together, as `cat a.gz b.gz` produces, are read one after another.
Bytes after the last member that don't start a new one, often zero padding, are ignored, as
`gzip -d` ignores them.

### XML features

The parser reads the subset of XML 1.0 that XMLTV uses. It handles:

- elements and attributes, with either quote style
- the five predefined entities and numeric character references
- CDATA sections, comments and processing instructions
- a DOCTYPE with an internal subset

It does not support these, and documents that need them are better read with a general XML
processor:

- **Entities declared in a DTD.** Their references are kept literally, with a diagnostic. No
  feed in the test corpus declares any.
- **Namespaces.** A prefixed name is just an unknown element.
- **XML 1.1** and encodings not listed above.
- **External DTDs.** They are never fetched. This also rules out external-entity attacks.

### Limits

Elements inside a skipped extension element may nest up to 1,024 levels deep. Deeper input is
reported as malformed rather than being allowed to exhaust memory. There is no limit on the
number of attributes, the length of a value or the size of a document.
