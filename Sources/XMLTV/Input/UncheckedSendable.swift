/// Lets the parallel loops share buffers that each iteration only touches at its own index or
/// slice: the parallel parse in ``DocumentDriver`` and the parallel file read in
/// ``DocumentInput``.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
