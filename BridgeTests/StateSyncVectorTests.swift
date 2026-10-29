import Foundation
import Testing

@Suite("state-sync.json")
struct StateSyncVectorTests {
    @Test("the rendered fields are the ones the diff compares")
    func renderedFields() throws {
        let file = try #require(Vectors.stateSync)
        let info = NotificationInfo(
            key: "k", pkg: "p", appLabel: "a", title: "t", text: "x", when: 0, threadId: nil, canReply: false,
            isClearable: true, iconHash: nil
        )
        let labels = Mirror(reflecting: RenderedContent(info)).children.compactMap(\.label)
        #expect(labels == file.renderedFields)
    }

    @Test(arguments: Vectors.stateSync?.cases ?? [])
    func diff(_ vector: StateSyncFile.Case) {
        let mirror = Dictionary(
            vector.mirror.map { (Signal.keyHash(of: $0.key), MirrorEntry(info: $0, hasIcon: false)) },
            uniquingKeysWith: { _, last in last }
        )
        let diff = StateSyncDiff.compute(mirror: mirror, activeSet: vector.activeSet)

        let added = diff.added.map(\.key)
        let updated = diff.updated.map(\.new.key)
        let removed = diff.removed
        let untouched = diff.untouched.map(\.info.key)
        #expect(Set(added) == Set(vector.expect.added), "added")
        #expect(Set(updated) == Set(vector.expect.updated), "updated")
        #expect(Set(removed) == Set(vector.expect.removed.map(Signal.keyHash(of:))), "removed")
        #expect(Set(untouched) == Set(vector.expect.untouched), "untouched")

        let all = added + updated + untouched + vector.mirror.filter { removed.contains(Signal.keyHash(of: $0.key)) }
            .map(\.key)
        #expect(all.count == Set(all).count, "every key lands in exactly one bucket, once")
        #expect(Set(all) == Set(vector.mirror.map(\.key) + vector.activeSet.map(\.key)), "no key is lost")

        for update in diff.updated {
            #expect(RenderedContent(update.old.info) != RenderedContent(update.new))
        }
        let last = Dictionary(vector.activeSet.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for info in diff.added {
            #expect(info == last[info.key], "an addition carries the last content of its key")
        }
    }
}
