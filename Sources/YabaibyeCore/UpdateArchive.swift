import Foundation

/// Only the simple, bounded ZIP shape produced by our release packager is accepted.
/// Validate local headers as well as the central directory before invoking ditto.
public enum UpdateArchive {
    public static func isSafe(_ data: Data) -> Bool {
        func word(_ offset: Int, _ size: Int) -> UInt64? {
            guard offset >= 0, offset + size <= data.count else { return nil }
            return (0..<size).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func safeExtras(start: Int, size: Int) -> Bool {
            let end = start + size
            guard start >= 0, end <= data.count else { return false }
            var position = start
            var identifiers = Set<UInt64>()
            while position < end {
                guard position + 4 <= end,
                      let identifier = word(position, 2), let length = word(position + 2, 2),
                      identifiers.insert(identifier).inserted,
                      position + 4 + Int(length) <= end else { return false }
                // ditto's release ZIPs use Info-ZIP Unix timestamps/UIDs only.
                // Reject ASi Unix (0x756e), PKWARE Unix (0x000d) and unknown
                // extensions: they may encode file types or link targets that
                // disagree with the central directory's regular-file mode.
                guard identifier == 0x5855, length == 8 || length == 12 else { return false }
                position += 4 + Int(length)
            }
            return position == end
        }
        guard data.count >= 22, data.count <= 128 * 1024 * 1024 else { return false }
        let lower = max(0, data.count - 65557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            word($0, 4) == 0x06054b50 && $0 + 22 + Int(word($0 + 20, 2) ?? 0) == data.count
        }), word(end + 4, 2) == 0, word(end + 6, 2) == 0,
              let entries = word(end + 10, 2), entries > 0, entries <= 5000,
              word(end + 8, 2) == entries, let offset = word(end + 16, 4),
              let size = word(end + 12, 4), offset + size == UInt64(end) else { return false }
        var cursor = Int(offset), total: UInt64 = 0, names = Set<String>()
        for _ in 0..<entries {
            guard word(cursor, 4) == 0x02014b50,
                  let flags = word(cursor + 8, 2), flags & 1 == 0,
                  let method = word(cursor + 10, 2), [0, 8].contains(method),
                  let expanded = word(cursor + 24, 4), expanded != 0xffffffff,
                  let nameSize = word(cursor + 28, 2), let extraSize = word(cursor + 30, 2),
                  let commentSize = word(cursor + 32, 2), word(cursor + 34, 2) == 0,
                  let attributes = word(cursor + 38, 4),
                  let local = word(cursor + 42, 4), local < offset else { return false }
            let mode = (attributes >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { return false }
            let start = cursor + 46, finish = start + Int(nameSize)
            guard finish <= data.count, let name = String(data: data[start..<finish], encoding: .utf8),
                  safePath(name), names.insert(name).inserted,
                  word(Int(local), 4) == 0x04034b50,
                  word(Int(local) + 6, 2) == flags, word(Int(local) + 8, 2) == method,
                  word(Int(local) + 26, 2) == nameSize,
                  let localExtra = word(Int(local) + 28, 2),
                  let compressed = word(cursor + 20, 4) else { return false }
            let localName = Int(local) + 30
            guard localName + Int(nameSize) <= data.count,
                  safeExtras(start: finish, size: Int(extraSize)),
                  safeExtras(start: localName + Int(nameSize), size: Int(localExtra)),
                  data[localName..<(localName + Int(nameSize))] == data[start..<finish],
                  UInt64(localName) + nameSize + localExtra + compressed <= offset else { return false }
            total += expanded
            guard total <= 512 * 1024 * 1024 else { return false }
            cursor = finish + Int(extraSize + commentSize)
            guard cursor <= end else { return false }
        }
        return cursor == end && names.contains("Yabaibye.app/Contents/Info.plist") &&
            names.contains("Yabaibye.app/Contents/MacOS/Yabaibye")
    }
    private static func safePath(_ path: String) -> Bool {
        guard !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
              path.hasPrefix("Yabaibye.app/") || path.hasPrefix("__MACOSX/Yabaibye.app/") ||
                path == "__MACOSX/" || path == "__MACOSX/._Yabaibye.app" else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.enumerated().allSatisfy { index, value in
            value != "." && value != ".." && (!value.isEmpty || index == parts.count - 1)
        }
    }
}
