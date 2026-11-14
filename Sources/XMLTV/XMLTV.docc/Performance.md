# Performance

What the parser costs, where the time goes, and which options change it.

## Overview

### Measurements

Apple M4 Max with 12 performance and 4 efficiency cores, Swift 6.4, release build, warm page
cache. Each figure is the median of 7 runs. Every figure builds the complete model, every DTD
field, unless the column says otherwise.

| Feed | Size | ``XMLTVDocument`` | One thread | ``XMLTVReader`` | Keeping 1/64 of channels |
|---|---:|---:|---:|---:|---:|
| epgshare01 ALL_SOURCES | 1.93 GB | 442 ms, 4.36 GB/s | 0.56 GB/s | 0.47 GB/s | 15.5 GB/s |
| epgshare01 US2, dense | 78 MB | 18.2 ms, 4.29 GB/s | 0.56 GB/s | 0.48 GB/s | 13.6 GB/s |
| epgshare01 DE1, many credits | 25 MB | 7.2 ms, 3.52 GB/s | 0.55 GB/s | 0.46 GB/s | 9.9 GB/s |
| Plex US, sparse | 15.5 MB | 4.5 ms, 3.48 GB/s | 0.59 GB/s | 0.47 GB/s | 8.6 GB/s |
| Pluto TV US | 7.7 MB | 2.8 ms, 2.81 GB/s | 0.59 GB/s | 0.49 GB/s | 8.0 GB/s |

For comparison, on the 1.93 GB feed:
- Foundation's `XMLParser`, with a delegate building only the common fields, runs at
  0.05 GB/s, taking 39 seconds.
- libxml2's SAX2 interface runs at 0.49 GB/s doing nothing but counting elements.

The library is about 88 times faster than the first while doing more work, and 8.9 times faster
than the second while building the whole model.

Run the benchmarks yourself with the harness in `Benchmarks/xmltv-bench`:

```
swift build -c release
.build/release/xmltv-bench document path/to/guide.xml
```

Its modes are `document`, `document-mmap`, `serial`, `reader`, `filter` and `foundation`.

### Where the time goes

A dense XMLTV feed has one `<` every 37 bytes on average, and most text runs are a few bytes:
indentation, `en`, a timestamp, a short title. Raw scanning bandwidth therefore matters less
than the fixed cost per element. On one core:

- a fifth of the time goes to tokenizing
- a fifth to turning bytes into strings, which includes UTF-8 validation
- a fifth to allocation and reference counting
- the rest to the decoder's own logic and array growth

Each core does about 0.56 GB/s. With 16 cores the parallel parse reaches about 8.8 times that,
not 16. Two things account for most of the gap:
- The efficiency cores are about half as fast as the performance cores.
- Profiles show threads waiting on locks inside `malloc`, so allocation is the likely limit on
  the rest. That has not been proven.

### The techniques

Each of these was measured against alternatives on the real feeds. <doc:DesignDecisions> has the
trade-offs.

- **One 16-byte vector search per text run.** It finds the next `<` and also flags `&` and
  carriage returns. About 95% of values need no decoding at all.
- **Tokens are byte offsets.** Attributes are parsed in the same pass that finds the `>`. No
  token allocates.
- **The scanner and decoder are fused.** The decoder is recursive descent, one function per
  element, reading tokens directly. There are no callbacks or events between them.
- **Strings are made once.** Text is trimmed by moving offsets, decoded only if the search
  flagged it, and validated by a specialised checker.
- **Repeated strings are shared.** Each worker keeps a hash table of the strings it has made, up
  to 4 KiB long. EPG text repeats constantly: channel IDs, categories, ratings, credit names,
  episodic titles, and descriptions of reruns. A repeat costs a hash and a compare, with no
  allocation.
- **Arrays sized from the previous programme.** Feeds are uniform, so a programme's ratings or
  categories array is usually allocated once at the right size instead of growing 1, 2, 4.
- **Timestamps go straight to integers.** There is no `Calendar` and no `DateFormatter`. See
  <doc:Timestamps>.
- **Parallel chunks, verified.** The input is split at likely `<programme` positions, decoded on
  all cores, and then checked so that the result is exactly what a serial parse gives.

### Options that change the cost

#### Filtering

``ParseOptions/channelIDs`` and ``ParseOptions/timeWindow`` are tested before a programme's
children are decoded. A rejected programme is skipped by a scan that jumps from one `<` to the
next. It still checks the markup but builds nothing. When an app needs a few hundred channels
out of a 30,000-channel guide, filtering is the biggest speed-up available: 15 GB/s instead of
4.4 GB/s on the 1.93 GB feed.

#### Parallelism

``ParseOptions/Parallelism/automatic`` uses every core for inputs of 1 MiB or more.
``ParseOptions/Parallelism/threads(_:)`` caps the number of worker threads, which is useful on a
server that has other work to do. ``ParseOptions/Parallelism/serial`` uses one thread. The
output is the same either way.

#### File access

``ParseOptions/FileAccess/read``, the default, reads the file into memory. Files of 64 MiB or
more are read in parallel slices, which makes this as fast as memory-mapping.
``ParseOptions/FileAccess/memoryMapped`` saves the copy. But if another process truncates the
file during the parse, the process crashes with SIGBUS. EPG grabbers often rewrite guides in
place, so mapping is opt-in.

#### Compressed input

Gzip decompression is single-threaded, at about 2.5 GB/s of output. For `.xml.gz` input it, not
the parser, sets the overall speed.

#### Teardown

Freeing a parsed 1.93 GB guide takes about 0.55 seconds, longer than parsing it, because it
releases millions of strings and arrays one at a time. <doc:ChoosingAnEntryPoint> shows how to
move that cost off the main thread.
