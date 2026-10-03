// Which pills the island shows when more integrations are active than it has room for (#111).
// Pinned pills never rotate out, pills with unseen news jump in at once, and the remaining
// slots rotate through the rest. The result keeps the order of `ids`. Mirrors the Mac's PillRotation.

export const PILL_SLOTS = 4;

/** `offset` only grows; it wraps over the rotating pool. */
export function visiblePillIds(
  ids: string[],
  opts: { pinned?: Iterable<string>; news?: Iterable<string>; offset: number; limit?: number },
): string[] {
  const limit = opts.limit ?? PILL_SLOTS;
  if (limit <= 0) return [];
  if (ids.length <= limit) return ids;

  const pinned = new Set(opts.pinned ?? []);
  const news = new Set(opts.news ?? []);
  const chosen: string[] = ids.filter((id) => pinned.has(id)).slice(0, limit);
  for (const id of ids) {
    if (chosen.length < limit && news.has(id) && !chosen.includes(id)) chosen.push(id);
  }
  const pool = ids.filter((id) => !chosen.includes(id));
  const free = limit - chosen.length;
  if (free > 0 && pool.length > 0) {
    const start = ((opts.offset % pool.length) + pool.length) % pool.length;
    for (let i = 0; i < Math.min(free, pool.length); i++) chosen.push(pool[(start + i) % pool.length]);
  }
  const picked = new Set(chosen);
  return ids.filter((id) => picked.has(id));
}
