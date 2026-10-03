// Now playing (#107): the port's pure logic: state parsing per player, which player is the
// active one, and command validation. No I/O here. The macOS twin is NowPlaying.swift and the two
// must agree (same cases in the tests). Nothing is stored: states live in memory and are replaced
// on each event.

export type Player = "music" | "spotify";
export type PlaybackState = "playing" | "paused" | "stopped";

export interface Track {
  /** Used only to notice a track change (never stored or sent anywhere). */
  id: string | null;
  title: string;
  artist: string;
  album: string;
  durationMs: number | null;
}

export interface NowPlayingState {
  player: Player;
  state: PlaybackState;
  track: Track | null;
  /** Position in ms at `updatedAt` (null when the source doesn't say). */
  positionMs: number | null;
  /** 0...100, null when unknown. */
  volume: number | null;
  /** Apple Music only. */
  favorited: boolean | null;
  /** Epoch ms of the event; used to extrapolate the position and to pick the last used player. */
  updatedAt: number;
}

export const BUNDLE_IDS: Record<Player, string> = {
  music: "com.apple.Music",
  spotify: "com.spotify.client",
};
/** The distributed notifications, the only trigger (no polling). */
export const NOTIFICATIONS: Record<Player, string> = {
  music: "com.apple.Music.playerInfo",
  spotify: "com.spotify.client.PlaybackStateChanged",
};

function stopped(player: Player, now: number): NowPlayingState {
  return { player, state: "stopped", track: null, positionMs: null, volume: null, favorited: null, updatedAt: now };
}

function parseState(raw: unknown): PlaybackState | null {
  if (typeof raw !== "string") return null;
  switch (raw.trim().toLowerCase()) {
    case "playing": return "playing";
    case "paused": return "paused";
    case "stopped": return "stopped";
    default: return null;
  }
}

function num(raw: unknown): number | null {
  if (typeof raw === "number") return Number.isFinite(raw) ? raw : null;
  if (typeof raw === "string" && raw.trim() !== "") {
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function text(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

/** Nothing real lasts longer than a day: bigger numbers are garbage (and would overflow Int in Swift). */
export const MAX_MS = 86_400_000;

function positiveMs(raw: unknown): number | null {
  const n = num(raw);
  return n !== null && n > 0 && n <= MAX_MS ? Math.round(n) : null;
}

function positionMs(raw: number | null): number | null {
  return raw !== null && raw >= 0 && raw <= MAX_MS ? Math.round(raw) : null;
}

/**
 * The userInfo of `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged`.
 * Keys as observed in the wild (neither Apple nor Spotify documents them): "Player State",
 * "Name", "Artist", "Album"; Music: "Total Time" (ms), "Persistent ID"; Spotify: "Duration" (ms),
 * "Playback Position" (s), "Track ID".
 */
export function parseNotification(player: Player, info: Record<string, unknown>, now: number): NowPlayingState | null {
  const state = parseState(info["Player State"]);
  if (!state) return null;
  if (state === "stopped") return stopped(player, now);
  const title = text(info["Name"]);
  if (!title) return null;
  const idRaw = player === "music" ? info["Persistent ID"] : info["Track ID"];
  const id = idRaw === undefined || idRaw === null || String(idRaw) === "" ? null : String(idRaw);
  const durationMs = positiveMs(player === "music" ? info["Total Time"] : info["Duration"]);
  const posSec = player === "spotify" ? num(info["Playback Position"]) : null;
  return {
    player,
    state,
    track: { id, title, artist: text(info["Artist"]), album: text(info["Album"]), durationMs },
    positionMs: positionMs(posSec === null ? null : posSec * 1000),
    volume: null,
    favorited: null,
    updatedAt: now,
  };
}

/**
 * The reply of `stateScript`: "stopped", or 8 tab-separated fields: state, name, artist, album,
 * durationMs, positionMs, volume, favorited ("" when the player has no such thing). Integers
 * only, so the locale's decimal separator can't break it.
 */
export function parseScriptReply(player: Player, reply: string, now: number): NowPlayingState | null {
  const line = reply.replace(/[\r\n]+$/, "");
  if (line.trim().toLowerCase() === "stopped") return stopped(player, now);
  const f = line.split("\t");
  if (f.length !== 8) return null;
  const state = parseState(f[0]);
  if (!state || state === "stopped") return null;
  const title = f[1].trim();
  if (!title) return null;
  const pos = num(f[5]);
  const vol = num(f[6]);
  const fav = f[7].trim().toLowerCase();
  return {
    player,
    state,
    track: { id: null, title, artist: f[2].trim(), album: f[3].trim(), durationMs: positiveMs(f[4]) },
    positionMs: positionMs(pos),
    volume: vol !== null && vol >= 0 && vol <= 100 ? Math.round(vol) : null,
    favorited: fav === "true" ? true : fav === "false" ? false : null,
    updatedAt: now,
  };
}

export const PLAYERS: Player[] = ["music", "spotify"];

/** The player to show: one playing wins (the most recent if several), else the last one used. A tie goes to the first in PLAYERS. */
export function pickActive(states: Partial<Record<Player, NowPlayingState>>): NowPlayingState | null {
  const live = PLAYERS.map((p) => states[p]).filter((s): s is NowPlayingState => !!s && s.state !== "stopped" && !!s.track);
  const latest = (list: NowPlayingState[]) =>
    list.reduce<NowPlayingState | null>((best, s) => (!best || s.updatedAt > best.updatedAt ? s : best), null);
  return latest(live.filter((s) => s.state === "playing")) ?? latest(live);
}

/** The position to draw now, extrapolated from the last event (no polling for the progress bar). */
export function positionAt(s: NowPlayingState, now: number): number | null {
  if (s.positionMs === null) return null;
  const elapsed = s.state === "playing" ? Math.max(0, now - s.updatedAt) : 0;
  const p = s.positionMs + elapsed;
  const d = s.track?.durationMs ?? null;
  return d !== null ? Math.min(p, d) : p;
}

// MARK: commands

export type Command =
  | { kind: "play" }
  | { kind: "pause" }
  | { kind: "toggle" }
  | { kind: "next" }
  | { kind: "previous" }
  | { kind: "seek"; seconds: number }
  | { kind: "skip"; seconds: number }
  | { kind: "volume"; percent: number };

export type ValidCommand =
  | { kind: "play" | "pause" | "toggle" | "next" | "previous" }
  | { kind: "seek"; positionMs: number }
  | { kind: "volume"; percent: number };

export type CommandError = "notFinite" | "nothingPlaying" | "unknownPosition";

export type Validation = { ok: true; command: ValidCommand } | { ok: false; error: CommandError };

/** Checks a command against the state it'll be applied to and returns the exact one to send. */
export function validateCommand(cmd: Command, state: NowPlayingState | null, now: number): Validation {
  switch (cmd.kind) {
    case "play": case "pause": case "toggle": case "next": case "previous":
      return { ok: true, command: { kind: cmd.kind } };
    case "volume":
      if (!Number.isFinite(cmd.percent)) return { ok: false, error: "notFinite" };
      return { ok: true, command: { kind: "volume", percent: Math.min(100, Math.max(0, Math.round(cmd.percent))) } };
    case "seek": case "skip": {
      if (!Number.isFinite(cmd.seconds)) return { ok: false, error: "notFinite" };
      if (!state || !state.track || state.state === "stopped") return { ok: false, error: "nothingPlaying" };
      let target = cmd.seconds * 1000;
      if (cmd.kind === "skip") {
        const here = positionAt(state, now);
        if (here === null) return { ok: false, error: "unknownPosition" };
        target += here;
      }
      const d = state.track.durationMs;
      target = Math.max(0, Math.min(target, d ?? MAX_MS));
      return { ok: true, command: { kind: "seek", positionMs: Math.round(target) } };
    }
  }
}

function seconds(ms: number): string {
  const m = Math.max(0, Math.round(ms));
  return `${Math.floor(m / 1000)}.${String(m % 1000).padStart(3, "0")}`;
}

/** AppleScript for a validated command. Only numbers produced by `validateCommand` are interpolated. */
export function commandScript(player: Player, cmd: ValidCommand): string {
  let body: string;
  switch (cmd.kind) {
    case "play": body = "play"; break;
    case "pause": body = "pause"; break;
    case "toggle": body = "playpause"; break;
    case "next": body = "next track"; break;
    case "previous": body = "previous track"; break;
    case "seek": body = `set player position to ${seconds(cmd.positionMs)}`; break;
    case "volume": body = `set sound volume to ${Math.round(cmd.percent)}`; break;
  }
  return `tell application id "${BUNDLE_IDS[player]}" to ${body}`;
}

/**
 * AppleScript that answers with the format `parseScriptReply` reads. Run it only while the app is
 * running: `tell application id` would launch it otherwise.
 */
export function stateScript(player: Player): string {
  const durationMs = player === "music" ? "round ((duration of current track) * 1000)" : "(duration of current track)";
  const favorited = player === "music" ? "(favorited of current track) as text" : '""';
  return [
    `tell application id "${BUNDLE_IDS[player]}"`,
    `  if player state is playing then`,
    `    set st to "playing"`,
    `  else if player state is paused then`,
    `    set st to "paused"`,
    `  else`,
    `    return "stopped"`,
    `  end if`,
    `  set t to character id 9`,
    `  set dur to 0`,
    `  try`,
    `    set dur to ${durationMs}`,
    `  end try`,
    `  set fav to ""`,
    `  try`,
    `    set fav to ${favorited}`,
    `  end try`,
    `  return st & t & (name of current track) & t & (artist of current track) & t & (album of current track) & t & (dur as integer) & t & (round ((player position) * 1000)) & t & (sound volume as integer) & t & fav`,
    `end tell`,
  ].join("\n");
}
