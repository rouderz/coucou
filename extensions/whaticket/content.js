// Coucou for WhaTicket — runs in your whaticket.com tab.
//
// Every few seconds it hands the tab's session token (the one the web app keeps in
// this page's localStorage) to the extension's background, which reads your queue
// with it. Nothing else on the page is read or changed, and when the tab closes
// Coucou simply stops seeing the queue.

"use strict";

function sessionToken() {
  try {
    const raw = localStorage.getItem("token");
    if (!raw) return null;
    const value = JSON.parse(raw);
    return typeof value === "string" && value ? value : null;
  } catch {
    return null;
  }
}

async function tick() {
  let reply = null;
  try {
    reply = await chrome.runtime.sendMessage({ type: "tick", token: sessionToken() });
  } catch {
    // The extension was reloaded or updated: this page's script is orphaned. Stop.
    return;
  }
  const seconds = Math.max(5, Math.min(60, Number(reply && reply.interval) || 15));
  setTimeout(tick, seconds * 1000);
}

tick();
