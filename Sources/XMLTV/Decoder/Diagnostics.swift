/// Applies the error policy to recoverable problems. In `.strict` mode a report throws. In
/// `.lenient` mode it is recorded and decoding continues.
///
/// Reports are held as pending until the decoder finishes the top-level element they belong
/// to, then committed sorted by offset. That has two effects:
/// - Diagnostics stay in document order even though an element's own problems, such as a
///   missing title, are only known after its children.
/// - Abandoning a partly decoded record, as the streaming driver does before a retry, is just a
///   matter of dropping what is pending.
struct Diagnostics {
    let policy: XMLTVOptions.Policy
    let sampleLimit: Int
    /// Whether to keep every committed offset. The parallel driver needs them to count exactly the
    /// diagnostics inside the part of a chunk it keeps. The streaming driver does not, and keeping
    /// them would make its memory grow with the file.
    let recordsOffsets: Bool

    /// The first `sampleLimit` committed diagnostics. Line numbers are filled in by the driver.
    private(set) var samples: [XMLTVDiagnostic] = []
    /// The offset of every committed diagnostic, ascending, when `recordsOffsets` is set.
    private(set) var offsets: [Int] = []
    /// The code and recovery of every committed diagnostic, parallel to `offsets`, so the
    /// parallel driver can count the ones in the part of a chunk it keeps.
    private(set) var outcomes: [(code: XMLTVError.Code, recovery: XMLTVDiagnostic.Recovery)] = []
    /// Counts of every committed diagnostic.
    private(set) var totals = XMLTVReport()
    var count: Int { totals.diagnosticCount }
    private var pending: [XMLTVDiagnostic] = []

    init(policy: XMLTVOptions.Policy, sampleLimit: Int, recordsOffsets: Bool) {
        self.policy = policy
        self.sampleLimit = sampleLimit
        self.recordsOffsets = recordsOffsets
    }

    /// Diagnostics reported for the current element so far.
    var pendingCount: Int { pending.count }

    @inline(__always)
    mutating func report(_ kind: XMLTVError.Kind, _ recovery: XMLTVDiagnostic.Recovery, at offset: Int) throws(XMLTVError) {
        if policy == .strict { throw XMLTVError(kind, byteOffset: offset) }
        pending.append(XMLTVDiagnostic(kind: kind, recovery: recovery, byteOffset: offset, line: 0))
    }

    /// Commits the pending diagnostics in document order.
    @inline(__always)
    mutating func commit() {
        guard !pending.isEmpty else { return }
        if pending.count > 1 {
            // Stable: equal offsets keep the order they were reported in.
            pending = pending.enumerated()
                .sorted { ($0.element.byteOffset, $0.offset) < ($1.element.byteOffset, $1.offset) }
                .map(\.element)
        }
        for diagnostic in pending {
            totals.count(diagnostic.kind.code, diagnostic.recovery)
            if recordsOffsets {
                offsets.append(diagnostic.byteOffset)
                outcomes.append((diagnostic.kind.code, diagnostic.recovery))
            }
            if samples.count < sampleLimit { samples.append(diagnostic) }
        }
        pending.removeAll(keepingCapacity: true)
    }

    /// What a problem found at the end of the input cost. These are reported after every record,
    /// at the end of the document.
    static func recoveryAtEnd(_ kind: XMLTVError.Kind) -> XMLTVDiagnostic.Recovery {
        kind == .invalidEncoding ? .repaired : .restOfInputIgnored
    }

    mutating func discardPending() {
        pending.removeAll(keepingCapacity: true)
    }

    /// For samples committed since `index`, converts window-relative offsets to document offsets
    /// and fills in line numbers. The streaming driver calls this after each record.
    mutating func rebaseSamples(from index: Int, by delta: Int, line: (Int) -> Int) {
        for i in index..<samples.count {
            samples[i].line = line(samples[i].byteOffset)
            samples[i].byteOffset += delta
        }
    }
}
