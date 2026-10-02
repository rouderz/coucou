// Inbox events → island (macOS InboxStore.announceNew): the list behind the 🔔,
// and Mochi peeking out with what's new (a badge only in Do not disturb).

import { onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type InboxItem } from "../core/state";
import { dndActive } from "../core/dnd.ts";
import type { Island } from "./island";

interface InboxUpdate {
  items: InboxItem[];
  fresh: InboxItem[];
}

export function registerInboxHandlers(island: Island) {
  void onEvent<InboxUpdate>("inbox", ({ items, fresh }) => {
    State.inbox = items;
    State.notify();
    if (!fresh.length || State.paused) return;
    if (dndActive(State.settings.dndUntil)) return;
    Sound.play("question");
    // Never steal the view from something in progress.
    if (State.mode !== "expanded" && !State.pendingApproval) island.alert("inbox");
  });
}
