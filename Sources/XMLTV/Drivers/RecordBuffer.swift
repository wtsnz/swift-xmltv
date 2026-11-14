/// An append-only buffer whose elements can be moved out without retain/release traffic.
///
/// Each parallel chunk collects its programmes here. The final `[Programme]` is then assembled
/// with one bitwise move per chunk. Appending each chunk's `Array` to the result would copy
/// instead: one retain per string and array in every programme, then one release when the chunk
/// is freed, around 30 million atomic operations on the 1.93 GB benchmark feed.
struct RecordBuffer<Element>: ~Copyable {
    private var base: UnsafeMutablePointer<Element>
    private var capacity: Int
    private(set) var count = 0

    init(capacity: Int = 256) {
        self.capacity = max(capacity, 1)
        self.base = .allocate(capacity: self.capacity)
    }

    deinit {
        base.deinitialize(count: count)
        base.deallocate()
    }

    @inline(__always)
    mutating func append(_ element: consuming Element) {
        if count == capacity { grow() }
        (base + count).initialize(to: element)
        count &+= 1
    }

    /// Moves the elements from `start` onwards to `destination` and destroys the ones before
    /// it. Returns how many elements were moved. The buffer is empty afterwards.
    mutating func moveElements(from start: Int, to destination: UnsafeMutablePointer<Element>) -> Int {
        precondition(start >= 0 && start <= count)
        base.deinitialize(count: start)
        let moved = count - start
        destination.moveInitialize(from: base + start, count: moved)
        count = 0
        return moved
    }

    private mutating func grow() {
        let newCapacity = capacity * 2
        let newBase = UnsafeMutablePointer<Element>.allocate(capacity: newCapacity)
        newBase.moveInitialize(from: base, count: count)
        base.deallocate()
        base = newBase
        capacity = newCapacity
    }
}
