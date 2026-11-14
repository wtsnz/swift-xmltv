/// Checks text that is about to become a `String`: it must be well-formed UTF-8 and contain
/// only characters XML allows. That excludes C0 controls other than tab, LF and CR, and the
/// noncharacters U+FFFE and U+FFFF.
///
/// This exists for speed. The standard library's validating initializer,
/// `String(validating:as:)`, is generic over `Sequence` and is not specialized for buffers, so
/// each call does runtime generic-metadata lookups that cost more than the validation. Checking
/// here and then creating the string with `String(decoding:as:)` is several times faster, even
/// though that initializer validates the UTF-8 a second time (quickly; it never fails here).
/// Text in skipped subtrees is not checked: it never becomes a string.
enum TextValidation {
    /// The first problem in `bytes`, or nil if the text is valid.
    @inline(__always)
    static func firstProblem(in bytes: UnsafeBufferPointer<UInt8>) -> XMLTVError.Kind? {
        guard let base = bytes.baseAddress else { return nil }
        let count = bytes.count
        var i = 0
        // Printable ASCII is checked 16 bytes at a time. Most EPG text is printable ASCII, so a
        // block with anything else (a newline, an accented letter) takes the scalar path only
        // up to the next block boundary.
        let space = SIMD16<UInt8>(repeating: 0x20), delete = SIMD16<UInt8>(repeating: 0x7F)
        while i &+ 16 <= count {
            let block = ByteSearch.load(base, i)
            if ByteSearch.nibbleMask((block .< space) .| (block .> delete)) == 0 {
                i &+= 16
                continue
            }
            switch scalarStep(base, from: i, until: i &+ 16, count: count) {
            case .success(let next): i = next
            case .failure(let problem): return problem.kind
            }
        }
        switch scalarStep(base, from: i, until: count, count: count) {
        case .success: return nil
        case .failure(let problem): return problem.kind
        }
    }

    struct Problem: Error { var kind: XMLTVError.Kind }

    /// The scalar path: the well-formed byte sequences of Unicode Table 3-7, plus XML's `Char`
    /// production. Checks sequences starting before `limit` and returns the index after the last
    /// one, which may lie past `limit` when a sequence straddles it.
    private static func scalarStep(
        _ p: UnsafePointer<UInt8>, from start: Int, until limit: Int, count: Int
    ) -> Result<Int, Problem> {
        var i = start
        @inline(__always) func continuation(_ index: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
            index < count && range.contains(p[index])
        }
        let invalidUTF8 = Problem(kind: .invalidUTF8)
        while i < limit {
            let lead = p[i]
            switch lead {
            case 0x09, 0x0A, 0x0D, 0x20...0x7F:
                i &+= 1
            case 0x00...0x1F:
                return .failure(Problem(kind: .invalidCharacter(UInt32(lead))))
            case 0xC2...0xDF:
                guard continuation(i &+ 1) else { return .failure(invalidUTF8) }
                i &+= 2
            case 0xE0:
                guard continuation(i &+ 1, 0xA0...0xBF), continuation(i &+ 2) else { return .failure(invalidUTF8) }
                i &+= 3
            case 0xE1...0xEC, 0xEE:
                guard continuation(i &+ 1), continuation(i &+ 2) else { return .failure(invalidUTF8) }
                i &+= 3
            case 0xEF:
                guard continuation(i &+ 1), continuation(i &+ 2) else { return .failure(invalidUTF8) }
                // U+FFFE and U+FFFF are EF BF BE and EF BF BF.
                if p[i &+ 1] == 0xBF && p[i &+ 2] >= 0xBE {
                    return .failure(Problem(kind: .invalidCharacter(0xFFF0 | UInt32(p[i &+ 2] & 0x0F))))
                }
                i &+= 3
            case 0xED:
                guard continuation(i &+ 1, 0x80...0x9F), continuation(i &+ 2) else { return .failure(invalidUTF8) }
                i &+= 3
            case 0xF0:
                guard continuation(i &+ 1, 0x90...0xBF), continuation(i &+ 2), continuation(i &+ 3) else { return .failure(invalidUTF8) }
                i &+= 4
            case 0xF1...0xF3:
                guard continuation(i &+ 1), continuation(i &+ 2), continuation(i &+ 3) else { return .failure(invalidUTF8) }
                i &+= 4
            case 0xF4:
                guard continuation(i &+ 1, 0x80...0x8F), continuation(i &+ 2), continuation(i &+ 3) else { return .failure(invalidUTF8) }
                i &+= 4
            default:
                return .failure(invalidUTF8)
            }
        }
        return .success(i)
    }
}
