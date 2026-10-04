// Time per Linear issue (#114): hook events → the local time store.
// The session's Linear issue comes from #27 (`session.linear`); without one the
// time goes to "repo @ branch". Events are batched for 3 s, then added to the
// file the Settings window reads (re-read first, so manual edits made there are
// kept). Nothing here is ever uploaded, and nothing runs between hook events.

import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { hookTimeKind, parseStore, recordEvent, serializeStore, type TimeEvent } from "../core/timetrack.ts";
import { lastPathComponent } from "./labels.ts";

const BRANCH_TTL_MS = 60_000;
const SAVE_DELAY_MS = 3_000;

const branches = new Map<string, { branch: Promise<string | undefined>; at: number }>();
let pending: TimeEvent[] = [];
let timer: number | null = null;
let chain: Promise<void> = Promise.resolve();

/** The branch checked out in a folder, looked up at most once a minute. */
function branchOf(cwd: string): Promise<string | undefined> {
  const hit = branches.get(cwd);
  if (hit && Date.now() - hit.at < BRANCH_TTL_MS) return hit.branch;
  const branch = Bridge.gitBranch(cwd).then((b) => b ?? undefined, () => undefined);
  branches.set(cwd, { branch, at: Date.now() });
  return branch;
}

/** Called for every hook event (sessions on the card or not). */
export async function recordTime(name: string, sessionId: string, cwd: string, payload: Record<string, unknown>) {
  if (State.settings.timeTracking === false || !sessionId) return;
  const kind = hookTimeKind(name, payload);
  if (!kind) return;
  const at = Date.now();
  const branch = cwd ? await branchOf(cwd) : undefined;
  const session = State.sessions.find((s) => s.id === sessionId);
  const repo = lastPathComponent(cwd) || undefined;
  pending.push({
    session: sessionId, kind, at, repo, branch,
    issue: session?.linear ? { identifier: session.linear.identifier, title: session.linear.title } : null,
  });
  if (timer === null) timer = window.setTimeout(() => { timer = null; void flushTime(); }, SAVE_DELAY_MS);
}

/** Adds the waiting events to the file, one write at a time. */
export function flushTime(): Promise<void> {
  chain = chain.then(async () => {
    if (!pending.length) return;
    const batch = pending;
    pending = [];
    const text = await Bridge.timeStoreLoad();
    if (text === null) {
      // Couldn't read the file: keep the events rather than overwrite it.
      pending = [...batch, ...pending];
      return;
    }
    let store = parseStore(text);
    for (const e of batch.sort((a, b) => a.at - b.at)) store = recordEvent(store, e);
    try {
      await Bridge.timeStoreSave(serializeStore(store));
    } catch (err) {
      console.error("[coucou] time store not saved", err);
      pending = [...batch, ...pending];
    }
  });
  return chain;
}
