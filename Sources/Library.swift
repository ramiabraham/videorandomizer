import Foundation

/// Compact in-memory index of every .mp4 under a root directory, plus a lazy
/// shuffle over it. Nothing but names is held: ~70 bytes per clip, so 100k
/// clips cost a few MB and no file is opened until it is about to play.
final class Library {
    let root: String
    private var dirs: [String] = [""]   // directory paths relative to root
    private var names: [UInt8] = []     // all file names, concatenated UTF-8
    private var offsets: [UInt32] = [0] // names[offsets[i]..<offsets[i+1]] is clip i
    private var dirOf: [UInt32] = []    // index into dirs for clip i
    private var order: [UInt32] = []    // shuffle permutation, built incrementally
    private var cursor = 0

    var count: Int { dirOf.count }

    init(root: String) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        scan()
        order = Array(0..<UInt32(count))
    }

    /// Next clip of a random permutation: every clip plays once before any
    /// repeats. Incremental Fisher-Yates, so it is O(1) per pick.
    func next() -> URL? {
        guard count > 0 else { return nil }
        if cursor == count { cursor = 0 }
        order.swapAt(cursor, Int.random(in: cursor..<count))
        let i = Int(order[cursor])
        cursor += 1
        return url(at: i)
    }

    func reshuffle() { cursor = 0 }

    private func url(at i: Int) -> URL {
        let name = String(decoding: names[Int(offsets[i])..<Int(offsets[i + 1])], as: UTF8.self)
        let dir = dirs[Int(dirOf[i])]
        return URL(fileURLWithPath: root + "/" + (dir.isEmpty ? "" : dir + "/") + name)
    }

    private func scan() {
        let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
        var next = 0
        while next < dirs.count {
            let dirIndex = next
            let rel = dirs[dirIndex]
            let path = rel.isEmpty ? root : root + "/" + rel
            next += 1
            guard let dir = opendir(path) else { continue }
            defer { closedir(dir) }
            while let ent = readdir(dir) {
                let len = Int(ent.pointee.d_namlen)
                let p = UnsafeRawPointer(ent).advanced(by: nameOffset)
                    .assumingMemoryBound(to: UInt8.self)
                let name = UnsafeBufferPointer(start: p, count: len)
                // Skips ".", "..", hidden files and AppleDouble "._*" sidecars.
                if len == 0 || name[0] == UInt8(ascii: ".") { continue }

                var type = Int32(ent.pointee.d_type)
                if type == DT_UNKNOWN || type == DT_LNK {
                    var st = stat()
                    let full = path + "/" + String(decoding: name, as: UTF8.self)
                    guard stat(full, &st) == 0 else { continue }
                    let fmt = st.st_mode & S_IFMT
                    // Symlinked directories are not followed (avoids cycles).
                    type = fmt == S_IFREG ? DT_REG : (fmt == S_IFDIR && type == DT_UNKNOWN ? DT_DIR : DT_UNKNOWN)
                }
                if type == DT_DIR {
                    let sub = String(decoding: name, as: UTF8.self)
                    dirs.append(rel.isEmpty ? sub : rel + "/" + sub)
                } else if type == DT_REG, len > 4,
                          name[len - 4] == UInt8(ascii: "."),
                          name[len - 3] | 0x20 == UInt8(ascii: "m"),
                          name[len - 2] | 0x20 == UInt8(ascii: "p"),
                          name[len - 1] == UInt8(ascii: "4") {
                    names.append(contentsOf: name)
                    offsets.append(UInt32(names.count))
                    dirOf.append(UInt32(dirIndex))
                }
            }
        }
    }
}
