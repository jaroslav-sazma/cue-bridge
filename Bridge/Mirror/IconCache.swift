import Foundation

nonisolated struct IconCache: Sendable {
    let directory: URL

    init(directory: URL = URL.cachesDirectory.appending(path: "app.cue.bridge/icons", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func contains(_ hash: String) -> Bool {
        guard let url = url(for: hash) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func store(_ png: Data, hash: String) throws {
        guard let url = url(for: hash) else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try png.write(to: url, options: .atomic)
    }

    func png(_ hash: String) -> Data? {
        guard let url = url(for: hash) else { return nil }
        return try? Data(contentsOf: url)
    }

    // An attachment takes its file over, so it always gets a fresh copy of the cached icon.
    func attachmentCopy(_ hash: String) -> URL? {
        guard let source = url(for: hash), FileManager.default.fileExists(atPath: source.path) else { return nil }
        let copy = URL.temporaryDirectory.appending(path: "cue-icon-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    func wipe() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(for hash: String) -> URL? {
        IconHash.isWellFormed(hash) ? directory.appending(path: "\(hash).png") : nil
    }
}
