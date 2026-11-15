# Architecture

This document is for people changing the library. For using it, see the DocC documentation in
`Sources/XMLTV/XMLTV.docc`, which also explains the design trade-offs in `DesignDecisions.md`.

## Layers

Each layer calls only the one below it. Only the API and model are public.

```
API       XMLTVDocument  XMLTVReader  XMLTVItems  XMLTVSchedule  XMLTVOptions  XMLTVError  XMLTVReport
Model     TVInfo  Channel  Programme (+ nested Credit, Rating, EpisodeNumber, ...)  XMLTVTimestamp
Drivers   DocumentDriver  (split, decode in parallel, verify, stitch, merge)
          StreamDecoder   (UTF-8 window, retry of the incomplete record)
Decoder   XMLTVDecoder    (one method per element, filters, Diagnostics)
Values    TextDecoder  Interner  TimestampParser  TextValidation
Scanner   XMLScanner  ByteSearch  XMLTVElement
Input     DocumentInput  GzipInflater  EncodingDetector  Transcoder  ByteBuffer
```

| Directory | What lives there |
|---|---|
| `Sources/XMLTV/API` | public entry points, options, errors, report, and the schedule built on a document |
| `Sources/XMLTV/Model` | public value types; no parsing logic |
| `Sources/XMLTV/Drivers` | how input reaches the decoder: whole buffer in parallel, or a window |
| `Sources/XMLTV/Decoder` | XMLTV semantics: which element means what |
| `Sources/XMLTV/Values` | bytes to strings, timestamps and validated text |
| `Sources/XMLTV/Scanner` | XML tokens; the only code that reads 16 bytes at a time |
| `Sources/XMLTV/Input` | files, gzip and encodings, producing UTF-8 |
| `Sources/CZlib` | system zlib module map |
| `Benchmarks/xmltv-bench` | benchmark harness and the Foundation baseline |
| `Tests/XMLTVTests` | the test suite and its fixtures |

## Invariants

These are the rules the code relies on. Breaking one tends to pass most tests and then fail on
a real feed.

### The scanner's pointer never outlives its buffer

`XMLScanner` reads through a raw `UnsafePointer`. Every driver creates or rebinds the scanner
inside the scope that keeps the buffer alive:
- `DocumentDriver` works inside `withUTF8`.
- `StreamDecoder` calls `scanner.rebind(to:position:)` before every `decoder.next()`, because its
  window moves when it grows.

Nothing may hold a `ByteRange` or `RawAttribute` across a rebind.

### One call to `XMLTVDecoder.next` handles one top-level construct

A call consumes at most one top-level element: the root start tag, a channel, a programme, an
extension element, or `</tv>`. Every change of decoder phase ends the call that made it. The
streaming driver depends on this. When a call throws `unexpectedEndOfInput` on a non-final
window, it rewinds to where the call started and retries later. That is only exact if the failed
call changed nothing that the retry would see. The only state that survives a failed call is
caches. They are value-transparent: they change speed, never results. A value that produced a
diagnostic is never cached.

### Diagnostics are pending until the element completes

`Diagnostics.report` appends to a pending list. `XMLTVDecoder.next` commits it, sorted by offset,
when it returns. Consequences:
- Committed diagnostics are in document order. `DocumentDriver` relies on this for binary
  searches and line numbering.
- A streaming retry discards exactly the failed call's diagnostics.
- Strict mode throws at the first report, before anything is pending.

### Parallel output equals serial output

`DocumentDriver.stitch` accepts a speculative chunk only from a position where the true,
sequential parse also stands at the top level. The argument is in the type's doc comment.
Anything that adds decoder state carried between top-level elements would break it:
- namespace scopes
- DTD-declared entities
- a phase that does not end the call that entered it

`ParallelTests` forces adversarial split points to catch this. Add cases there whenever the
decoder gains state.

### Moved, not copied

Chunk results hold programmes in a `RecordBuffer`. `assemble` moves them into the final array.
Copying would retain and then release every string and array once, which on the 1.93 GB feed
costs more than half a second.

## Tests

```
swift test
```

The suites, by file:

| File | Covers |
|---|---|
| `ScannerTests` | tokens, truncation versus malformation, search kernels at every alignment, element names |
| `TimestampTests` | the fast path against `Calendar`, truncated forms, zones, normalisation |
| `ModelTests` | every DTD field, encodings, gzip, whitespace and entity rules |
| `DifferentialTests` | an independent decoder built on Foundation's `XMLParser` |
| `ParallelTests` | parallel output equals serial output, on an adversarial document |
| `StreamingTests` | streamed items and reports equal the document's, at chunk sizes from 1 byte |
| `RobustnessTests` | truncation at every third byte, malformed input, random mutation |
| `RegressionTests` | one test per defect found in review |
| `APITests` | the app-facing contracts: reports after a loop, recovery outcomes and counts, error text, timestamps, schedules |
| `DocumentationExamplesTests` | the code examples from the README and the DocC articles |

Some tests also run on real feeds when they are available. Set `XMLTV_CORPUS` to a directory of
`.xml` files, or place them in `../Research/samples/real` next to the package. Files over 30 MB
are skipped to keep the suite quick. Without a corpus these tests have no cases and pass
trivially.

## Benchmarks

```
swift build -c release
.build/release/xmltv-bench <mode> <file> [repetitions]
```

Modes are `document`, `document-mmap`, `serial`, `reader`, `filter`, `foundation`, `chunks`,
`bytes` and `schedule`. The
harness reports the median and range, and times freeing the result separately. Close other
heavy work first. The parallel numbers are sensitive to load, and the single-thread numbers much
less so.

When you change the scanner, decoder or values layer, compare `serial` on a dense feed before
and after. When you change the drivers, compare `document` on the largest feed you have.

## Public API rules

- Guide data has plain names; the parser's own types are prefixed `XMLTV`. Never declare a
  type named `XMLTV`, which would break the `XMLTV.Channel` spelling apps use to disambiguate.
- An enum that may grow is `@nonexhaustive`. Adding a case to one is not breaking; adding the
  attribute to an existing closed enum is.
- `Programme` and `Channel` do not gain `Identifiable`, beyond `Channel`'s existing one, or
  `Codable`. The DocC catalog promises this, because a library conformance would silently
  replace one an app declared.
- Every diagnostic is reported with the `XMLTVDiagnostic.Recovery` that describes what it
  cost. A new recovery rule picks an existing case if one fits.

## Style

- Doc comments explain why. The code shows what.
- Hot paths use `&+` and similar wrapping arithmetic only where the bounds are already proven
  by the surrounding loop.
- `@inline(__always)` marks small functions on the per-byte or per-element path.
- No `unsafeFlags`, and no dependencies beyond zlib.
