# Choosing an entry point

Pick between a whole document, a pull reader and an async sequence, by memory and latency.

## Overview

All three entry points use the same decoder, so they produce identical channels, programmes
and reports. The test suite checks this at every chunk size down to one byte. They differ in
how much they hold in memory, whether they use more than one core, and when the first record
is available.

| | ``XMLTVDocument`` | ``XMLTVReader`` | ``XMLTVItems`` |
|---|---|---|---|
| Input | file, `Data` | file, `Data` | `AsyncSequence` of byte chunks |
| Cores | all, for inputs of 1 MiB or more | one | one |
| Memory | the whole result, plus the input | about one record, plus a 1 MiB read buffer | about one record, plus unread chunks |
| First record | after the whole parse | immediately | as soon as its bytes arrive |
| Speed on the 1.93 GB feed | 4.4 GB/s | 0.47 GB/s | network-bound |

### Whole documents

Use ``XMLTVDocument`` when the guide fits in memory and you want all of it. It is the fastest
path by a wide margin, because it is the only one that can split the input across cores.

The result costs memory in proportion to the guide. A fully parsed 1.93 GB feed peaks at about
5 GB of resident memory, including the input buffer, which is freed when the initializer
returns. Freeing the result takes about 0.55 seconds on one thread, and whichever thread drops
the last reference pays it. If that thread is the main thread, hand the old document to a
background queue when you replace it:

```swift
func replaceGuide(with newGuide: XMLTVDocument) {
    let oldGuide = currentGuide
    currentGuide = newGuide
    // The block holds the last reference once this function returns, so it frees the arrays.
    DispatchQueue.global(qos: .utility).async { _ = oldGuide }
}
```

### Records one at a time

Use ``XMLTVReader`` to insert records into a database, or to scan a guide too large to hold.
Each record is returned once, in document order, with channels and programmes interleaved as
they appear in the file.

```swift
var reader = try XMLTVReader(contentsOf: url)
while let item = try reader.next() {
    switch item {
    case .channel(let channel): try database.upsert(channel)
    case .programme(let programme): try database.insert(programme)
    }
}
print(reader.report.diagnosticCount, "problems recovered")
```

The reader is `~Copyable`: it owns an open file, and copying it would make two readers fight
over one position. Pass it `inout` or `consuming`.

> Note: ``XMLTVReader/next()`` returns nil only after it has read to the end of the input and
> checked everything after `</tv>`. A file with garbage after the root therefore fails at the
> end in strict mode, just as ``XMLTVDocument`` does.

### Records as they download

Use ``XMLTVItems`` to parse while the bytes arrive. It accepts any `AsyncSequence` whose
elements conform to `ContiguousBytes`, such as `Data` or `[UInt8]`.

```swift
var items = XMLTVItems(chunks: downloadChunks).makeAsyncIterator()
while let item = try await items.next() {
    if case .programme(let programme) = item { try await store.insert(programme) }
}
if items.report.isTruncated { showWarning("The download was cut off") }
```

Iteration is pull-driven, with no background task. Each call to `next()` decodes up to the next
record and reads more chunks only when it has to. A slow consumer therefore slows the download,
and memory stays bounded. Errors thrown by the chunk sequence come out of `next()` unchanged,
so a network failure stays a network failure and is not reported as bad XML.

To read the report, use the iterator directly, as above, rather than `for try await`. A
`for` loop hides the iterator.

#### Feeding chunk sequences efficiently

Feed chunks of a few kilobytes or more. `URLSession.AsyncBytes` yields one byte at a time, and
an `AsyncSequence` element per byte is slow in any Swift code. Group the bytes into chunks
first, or download with a delegate that delivers `Data`.

### Why there is no callback or visitor API

A pull reader can do anything a visitor can, at the same cost. It also reads as ordinary
control flow: `break` stops early, `try` propagates your own errors, and there are no
four-method protocols to implement. See <doc:DesignDecisions>.
