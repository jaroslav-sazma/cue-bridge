import Testing

@Suite("Menu bar state")
struct MenuBarStateTests {
    private func state(
        paired: Bool = true, unusable: Bool = false, connected: Bool = false,
        storageError: Bool = false, bluetoothProblem: Bool = false
    ) -> MenuBarState {
        MenuBarState(
            paired: paired, unusable: unusable, connected: connected,
            storageError: storageError, bluetoothProblem: bluetoothProblem
        )
    }

    @Test("a paired phone shows connected with a session and idle without one")
    func paired() {
        #expect(state(connected: true) == .connected)
        #expect(state() == .idle)
    }

    @Test("no pairing shows not paired, even while a pairing connection is up")
    func notPaired() {
        #expect(state(paired: false) == .notPaired)
        #expect(state(paired: false, connected: true) == .notPaired)
    }

    @Test("an unusable pairing or a storage error is a problem whatever else holds")
    func problems() {
        #expect(state(paired: false, unusable: true) == .problem)
        #expect(state(connected: true, storageError: true) == .problem)
        #expect(state(paired: false, storageError: true) == .problem)
    }

    @Test("Bluetooth trouble is a problem only while paired")
    func bluetooth() {
        #expect(state(connected: true, bluetoothProblem: true) == .problem)
        #expect(state(paired: false, bluetoothProblem: true) == .notPaired)
    }

    @Test("every state has its own symbol")
    func symbols() {
        let all: [MenuBarState] = [.notPaired, .idle, .connected, .problem]
        #expect(Set(all.map(\.symbol)).count == all.count)
    }
}
