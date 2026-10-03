import Foundation

/// Which pills the island shows when more integrations are active than it has room for (#111).
/// Pinned pills never rotate out, pills with unseen news jump in at once, and the remaining
/// slots rotate through the rest. The result keeps the order of `ids`.
enum PillRotation {
    static let slots = 4

    /// `offset` only grows; it wraps over the rotating pool.
    static func visible(ids: [String], pinned: Set<String> = [], news: Set<String> = [],
                        offset: Int, limit: Int = slots) -> [String] {
        guard limit > 0 else { return [] }
        if ids.count <= limit { return ids }

        var chosen: [String] = Array(ids.filter { pinned.contains($0) }.prefix(limit))
        for id in ids where chosen.count < limit && news.contains(id) && !chosen.contains(id) {
            chosen.append(id)
        }
        let pool = ids.filter { !chosen.contains($0) }
        let free = limit - chosen.count
        if free > 0 && !pool.isEmpty {
            let start = ((offset % pool.count) + pool.count) % pool.count
            for i in 0..<min(free, pool.count) { chosen.append(pool[(start + i) % pool.count]) }
        }
        let picked = Set(chosen)
        return ids.filter { picked.contains($0) }
    }
}
