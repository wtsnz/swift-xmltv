# Design decisions

The choices that shape the library, what each one costs, and the evidence behind it.

## Overview

Two engineers designed this library independently, each with a working prototype, and then
critiqued each other's designs against eight real feeds. After it was built, both reviewed the
code. The decisions below are where they disagreed, or where the obvious choice turned out to
be wrong. Each gives the alternative that was rejected, so you can judge whether the trade-off
suits you.

### Owned values, not views into the input

Every ``Channel`` and ``Programme`` is a plain struct of `String`s and arrays. It is `Sendable`
and `Hashable`, and it lives on after the parse.

The alternative was to hand out views that point into the input buffer and decode on access.
The prototype measured that ceiling at 26 GB/s, against about 4.4 GB/s for owned values, so
views are much faster. But a view cannot cross an `await` and cannot be stored, and one view
keeps the whole input buffer alive, which could be gigabytes. Almost every real consumer copies
the strings out anyway, into a database, a UI or JSON, so views would move the cost rather than
remove it.

The library keeps the fast path where it helps: filtering. ``ParseOptions/channelIDs`` and
``ParseOptions/timeWindow`` are checked against the raw bytes, so rejected programmes never
become values.

### A purpose-built XML scanner

The library reads XML with its own scanner, not `XMLParser` or libxml2. `XMLParser` reaches
0.05 GB/s on these feeds. libxml2's SAX2 interface reaches 0.5 GB/s just counting elements,
before any model is built. That is a ceiling for any parser built on it, and this library goes
nearly nine times faster while building the full model.

The cost is generality. The scanner handles the XML that XMLTV uses and checks it for
well-formedness, but it does not expand DTD-declared entities, resolve namespaces or read
XML 1.1. <doc:FormatSupport> lists exactly what is out. No feed in the test corpus uses any of
these.

### Rare fields in one shared box

`Programme` stores the fields most feeds fill in directly: titles, descriptions, categories,
credits, ratings, icons, episode numbers and times. The DTD's other fields, such as keywords,
reviews, images, video, audio and subtitles, live in one copy-on-write allocation. A programme
gets that allocation only if it uses one of them. Both kinds read and write the same way.

The stride is 176 bytes. A flat struct holding all of them is 656 bytes. At 2.9 million
programmes that is 0.5 GB against 1.9 GB of mostly empty fields, all of it moved during the
parallel merge and walked during teardown. The cost is one extra allocation for programmes
that use a rare field. Setting a rare field after parsing also allocates, because the box is
immutable. That is what makes it trivially `Sendable`.

### Lenient by default, but markup must be sound

Real feeds are imperfect in predictable ways. The 1.93 GB test feed has:
- 571 stop times with minute 60
- about 1,100 `<rating>` elements with text but no `<value>`
- about 1,900 fractional lengths

A cut-off download is the most common failure of all. Rejecting the whole guide for any of these
helps nobody, so lenient mode recovers each one with a fixed, documented rule and records a
diagnostic.

Damaged markup is different. Once an end tag doesn't match, the parser can no longer tell which
text belongs to which element, and any recovery would produce data that looks right and isn't.
So broken markup always throws, even in lenient mode. Strict mode exists for people who would
rather have nothing than something imperfect. <doc:ErrorsAndDiagnostics> has the rules.

### Diagnostics are part of the result

A diagnostic belongs to the record it was found in and is held until that record is complete,
then committed in offset order. This sounds like bookkeeping, but three things depend on it:
- Diagnostics come out in document order, with correct line numbers, even though a missing
  title is only discovered at `</programme>`.
- A streaming retry can abandon half a record and drop exactly its diagnostics.
- Parallel, serial and streaming parses produce identical reports.

That last point is tested at every chunk size. The code review found four ways the reports
could differ before this design was adopted.

### Parallel parsing by guessing and checking

To use every core, the input has to be split. A split must fall between records, or the halves
won't parse. Finding safe split points means tracking comments, CDATA and nesting, and that
takes a serial pass over the whole file. The prototype estimated such a pass would cap
throughput near 2.5 GB/s.

Instead the parser guesses. It splits at text that looks like `<programme` and decodes every
chunk at once. A guess can be wrong: the text might sit inside a comment, a CDATA section or an
extension element. So a sequential pass then checks each chunk. It accepts chunk *i* from the
first element start that equals the true position where chunk *i − 1* stopped. At a true
top-level position the decoder has no state left over: no open elements, no entities, no
namespaces. So from that point on the chunk's output is exactly what a serial parse produces.
A chunk that never lines up is decoded again from the true position, and that decoding switches
back to the chunk's output as soon as positions match.

This reaches 4.4 GB/s. The cost is complexity, and a test suite to match. Tests force every
candidate split at once, and 40 random sets of split points, on a document built to defeat the
guessing. They also check errors, truncation and filters, and compare the report as well as the
data. On a pathological document, such as one where every `<programme` text is inside a comment,
the speed falls back towards serial, but the output is still correct.

### Streaming by retrying, not by resuming

The streaming entry points decode from a window of input. When a record runs past the end of
the window, the decoder abandons it, waits for more input and decodes it again from the start.

The alternative was a scanner that can stop at any byte and resume later. That puts a "was I in
the middle of something?" check into every scanning loop. Retrying keeps those loops
straight-line and shared with the document parser. The retry waits until the pending input has
grown by half, so even a huge record in one-byte chunks costs linear time in total. With the
reader's 1 MiB reads, a few hundredths of a percent of the bytes are decoded twice.

### Deduplicating strings, including descriptions

Each worker keeps a table of the strings it has made, keyed by their bytes. The first plan
covered only short vocabulary: channel IDs, languages, categories. Measurement showed that
descriptions repeat too, in reruns and looping channels. Interning everything up to 4 KiB made
the 1.93 GB parse about 10% faster and lowered peak memory by about 6%.

Each worker has its own table, so no locks are needed. Sharing strings across cores would turn
every retain of a popular string into contended atomic traffic. Strings of 15 bytes or fewer
are stored inline in `String` and never allocate, so they skip the table. A value that needed
repair, such as one with invalid UTF-8, is never cached, so every occurrence reports its own
diagnostic.

### Our own UTF-8 check

`String(validating:as:)` would be the natural way to reject bad UTF-8. It is generic over
`Sequence` and not specialised for buffers, so every call does runtime generic-metadata
lookups. In the first profile those lookups took a quarter of the parse time. The library checks
the bytes itself, with a 16-byte fast path for printable ASCII that also enforces XML's
character rules. It then creates the string with `String(decoding:as:)`. That initializer
validates again, but quickly. It is still the fastest correct option the public API allows.

### Reading files, not mapping them, by default

Memory-mapping avoids a copy, but if another process truncates the file mid-parse, the parsing
process crashes with SIGBUS, and that cannot be caught. EPG grabbers commonly rewrite guides in
place, as in `tv_grab_xx > guide.xml`. Reading in parallel slices made the copy cheap enough that
the default path is as fast as mapping. Mapping remains available as
``ParseOptions/FileAccess/memoryMapped`` for files that are replaced atomically.

### Exact ISO-8859-1

XML defines ISO-8859-1 exactly: byte 0x80 is U+0080. Browsers decode the label as Windows-1252
instead, and so did the first design. The library follows XML, because a parser that disagrees
with every other XML tool about the same bytes is worse than one that occasionally needs an
override. Feeds that are mislabelled can set ``ParseOptions/encoding``.

### Zone names are never guessed

`IST` is India, Ireland and Israel. A guess would shift programmes by hours with no sign of
error. Only UTC, GMT, Z and BST are known by default, and an unknown name is a diagnostic, not a
silent assumption. See <doc:Timestamps>.

### Trim, but never collapse

Text is trimmed at both ends, and inner whitespace, including line breaks, is kept. Collapsing
runs of whitespace in descriptions was proposed, but the upstream `tv_cat` tool keeps them, and
a parser should not rewrite content.

### A pull reader, not a visitor

One design offered a visitor protocol with a callback for each kind of record. A pull reader
does the same work at the same cost, and it is ordinary control flow: `break` stops early, and
your own errors propagate with `try`. The async sequence follows the same pull model, with no
background task. A slow consumer applies backpressure, and there is nothing to cancel.

### Typed errors where only the parser can fail

The synchronous entry points use `throws(XMLTVError)`, so you can switch over every
``XMLTVError/Kind``. ``XMLTVItems`` uses untyped `throws`, because its chunk sequence can fail
with any error, and that error should arrive unchanged. A network failure should not be
disguised as bad XML.

### What was left out, and why

- **DTD entities, namespaces and XML 1.1.** No feed uses them, and supporting them would slow
  every other feed.
- **More encodings,** for example through iconv. Each would add a platform dependency to serve
  feeds that have not been seen in practice.
- **Keeping unknown elements.** They are skipped. Keeping them would need a generic tree type in
  the public API.
- **`Codable` conformance.** It would freeze the encoded layout of the rare-field box before the
  API is settled.
- **Parallel gzip.** The deflate format does not split cleanly. Decompression stays the limit
  for `.xml.gz`.
- **A borrowed-view API.** See the first section.

None of these rules anything out later. Each can be added without breaking the current API.
