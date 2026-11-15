# Choosing an entry point

Pick between a whole document, a pull reader and an async sequence, and use them from tasks
and actors.

## Overview

All three entry points use the same decoder, so they produce identical channels, programmes
and reports. The test suite checks this at chunk sizes from one byte up. They differ in
how much they hold in memory, whether they use more than one core, and when the first record
is available.

| | ``XMLTVDocument`` | ``XMLTVReader`` | ``XMLTVItems`` |
|---|---|---|---|
| Input | file, `Data`, or chunks | file, `Data` | `AsyncSequence` of byte chunks or bytes |
| Cores | all, for files and `Data` of 1 MiB or more; one for chunks | one | one |
| Memory | the whole result, plus the input | bounded: a 1 MiB read buffer, up to 1 MiB of decompressed gzip, a 4 MiB string table and one record, which ``XMLTVOptions/maximumRecordSize`` limits | bounded, as for the reader, plus unread chunks |
| First record | after the whole parse | immediately | as soon as its bytes arrive |

For a guide on the network, download it to a file and use ``XMLTVDocument``, unless you need
records before the download finishes.

### Whole documents

Use ``XMLTVDocument`` when the guide fits in memory and you want all of it. It is the fastest
path by a wide margin, because it is the only one that can split the input across cores.

The result costs memory in proportion to the guide. A fully parsed 1.93 GB feed peaks at about
5 GB of resident memory, including the input buffer, which is freed when the initializer
returns. Freeing the result takes about half a second on one thread, and whichever thread
drops the last reference pays it. If that thread is the main thread, hand the old document to a
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

Peak memory stays small however large the file, and however well it compresses: about 40 MiB
for the whole process while reading the 1.93 GB feed, plain or gzipped, against about 5 GB for
``XMLTVDocument``. Gzip input is decompressed 1 MiB at a time, as the reader needs it. Most of
the memory is a table of strings already made, which makes repeated text cheap. It holds the
first 4 MiB of distinct strings and then stops growing.

The rest is the record being read, so the bound holds for any input only because a record has
a limit: ``XMLTVOptions/maximumRecordSize``, 16 MiB by default. A guide's records are a few
kilobytes. Input built to exhaust memory, such as a 1.5 MB `.gz` that expands to a 1.5 GB
comment, throws ``XMLTVError/Kind/recordTooLarge(maximumSize:)`` instead, at about 60 MiB of
memory. Whitespace between records is not held, however long the run.

A reader is a single pass over its input, so it is noncopyable: a copy would be a second owner
taking records from the same cursor. The compiler enforces this, which means a reader is held
a little differently from other values:

- Keep it in a local `var`, a class, an actor, or a struct that is itself `~Copyable`. An
  ordinary struct property does not work, because the struct would be copyable.
- Pass it as `inout` to a function that reads from it, or `consuming` to hand it over.
- ``XMLTVReader/info`` is nil until the first call to ``XMLTVReader/next()``.

> Note: ``XMLTVReader/next()`` returns nil only after it has read to the end of the input and
> checked everything after `</tv>`. A file with garbage after the root therefore fails at the
> end in strict mode, just as ``XMLTVDocument`` does.

### Guides from the network

The simplest and fastest way to read a guide from a server is to download it, then parse the
file. Gzip is detected from the content, so the temporary file's name does not matter.

```swift
let (file, response) = try await URLSession.shared.download(from: guideURL)
guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badStatus }
let guide = try XMLTVDocument(contentsOf: file)
```

An error page from the server is reported as ``XMLTVError/Kind/notXMLTV``, whether it is
HTML, JSON or plain text. ``XMLTVDocument/init(contentsOf:options:)`` takes only file URLs and
throws ``XMLTVError/Kind/notAFileURL(_:)`` for others.

Keep the downloaded file as your cache. On the UK feed, parsing the 3 MB `.xml.gz` again takes
15 ms, while decoding a JSON cache of only the common fields takes 350 ms and is 23 MB. The
benchmark harness's `json` mode reproduces this.

### Records as they download

Use ``XMLTVItems`` to handle records while the bytes arrive: on a device without the memory
for the whole guide, or to fill a database during the download. It accepts any
`AsyncSequence` whose elements conform to `ContiguousBytes`, such as `Data` or `[UInt8]`, and,
through ``XMLTVItems/init(bytes:chunkSize:options:)``, a `Sendable` sequence of single bytes
such as `URLSession.AsyncBytes`.

```swift
let (bytes, response) = try await URLSession.shared.bytes(from: guideURL)
guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badStatus }
let items = XMLTVItems(bytes: bytes)
for try await item in items {
    if case .programme(let programme) = item { try await store.insert(programme) }
}
if let report = items.report, report.isTruncated {
    showWarning("The download was cut off")
}
```

A download cut off by the server ends the loop normally, after the last complete record, so
check ``XMLTVItems/report`` after the loop. It holds the report of the most recent iteration to
end. A loop that ends early, by `break` or a thrown error, also leaves a report, covering the
records read so far. While the loop runs, the iterator's ``XMLTVItems/AsyncIterator/report``
has the report so far, and its ``XMLTVReport/inputByteCount`` divided by the download's
expected length gives progress.

Errors thrown by the source come out of the loop unchanged, so a network failure stays a
network failure and is not reported as bad XML. Cancelling the task throws `CancellationError`,
even from a source such as `AsyncStream` that ends quietly when cancelled, so a cancelled
download is never mistaken for a cut-off guide. To collect everything instead of handling
records one by one, use ``XMLTVDocument/init(chunks:options:)``.

#### Speed and memory

Gathering single bytes into chunks costs more than parsing them. Through
``XMLTVItems/init(bytes:chunkSize:options:)``, `URLSession.AsyncBytes` reads a local guide at
about 200 MB/s, from the main actor or off it, against about 440 MB/s for 64 KiB `Data` chunks
and several GB/s for ``XMLTVDocument``. A network is usually slower than all of these. For the
fastest result, download to a file.

Iteration is pull-driven, with no background task. Each call to `next()` decodes up to the next
record and reads more chunks only when it has to. Decoding runs on the caller's actor, whether
through `for try await` or a call to `next()`: a loop on the main actor parses on the main
thread, in record-sized steps between suspensions. That is
fine in a release build, but a debug build parses at about 15 MB/s, so a large import on the
main actor holds it for seconds there; iterate in a `@concurrent` function instead.

Memory stays bounded as long as the source also waits to be asked, as `URLSession.AsyncBytes`
does. An `AsyncStream` that a delegate feeds with `Data` buffers whatever it is given, so a slow
consumer makes it grow. Do not give such a stream a dropping buffering policy: a dropped chunk
is lost XML.

### Concurrency

Documents, channels, programmes and reports are `Sendable` values, so they move freely between
tasks and actors.

#### Parse off the main actor

The ``XMLTVDocument`` file and `Data` initializers are synchronous and use every core until
they return.
A plain `Task { }` started from the main actor runs on the main actor, so the parse would block
it. Make the parse a `@concurrent` function instead, or run it in a detached task:

```swift
@concurrent
func loadGuide(from file: URL) async throws -> XMLTVDocument {
    try XMLTVDocument(contentsOf: file)
}

@MainActor
final class GuideModel {
    var guide: XMLTVDocument?

    func refresh(from file: URL) async throws {
        guide = try await loadGuide(from: file)
    }
}
```

#### Move a reader into a task or an actor

``XMLTVReader`` is `Sendable`, so a reader opened in one place can be read in another. Because
it is noncopyable, moving it is a transfer: the original variable can no longer be used.

```swift
actor Importer {
    private var reader: XMLTVReader

    init(reader: consuming XMLTVReader) {
        self.reader = reader
    }

    func importNext() throws -> XMLTVItem? {
        try reader.next()
    }
}

let importer = Importer(reader: try XMLTVReader(contentsOf: file))
```

To read in a task instead, capture the reader's variable. The task takes it over. This works
for a local variable in a function; at the top level of `main.swift`, a `var` is a global on
the main actor, and the task cannot take it.

```swift
var reader = try XMLTVReader(contentsOf: file)
let count = try await Task.detached {
    var count = 0
    while try reader.next() != nil { count += 1 }
    return count
}.value
```

#### Iterate items in an actor

`for try await` over ``XMLTVItems`` works in an actor method as anywhere else. If you need the
iterator itself, keep it in a local variable of the method. `next()` runs on the caller's
actor, as the loop does, so the chunks are read on the actor:

```swift
extension Importer {
    func importAll<Chunks>(_ items: XMLTVItems<Chunks>) async throws -> XMLTVReport {
        var iterator = items.makeAsyncIterator()
        while let item = try await iterator.next() {
            _ = item   // store it
        }
        return iterator.report
    }
}
```

An iterator stored in an actor property cannot be advanced with `await`, because the call
would hold exclusive access to the property across a suspension. An iterator is one cursor:
copies share their position.

``XMLTVItems`` is `Sendable` when its source is, so an unstarted sequence can be handed to
another task.

### Why there is no callback or visitor API

A pull reader can do anything a visitor can, at the same cost. It also reads as ordinary
control flow: `break` stops early, `try` propagates your own errors, and there are no
four-method protocols to implement. See <doc:DesignDecisions>.
