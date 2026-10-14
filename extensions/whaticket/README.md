# Lumo for WhaTicket

A small Chrome / Edge (and Brave, Chromium) extension that shows your
whaticket.com queue in Lumo and lets you accept tickets from the notch.

It uses the session you already have open in your whaticket.com tab — no API
token, no admin access, no password stored anywhere. It never renews the session
itself, so it can't sign your tab out.

## How it works

- `content.js` runs in your `app.whaticket.com` tab and hands the page's session
  token to the extension's background every ~15 seconds.
- `background.js` reads the pending queue and your open tickets with the same
  calls the web app makes, then sends a short summary to Lumo through native
  messaging (host `fr.louisraille.coucou`).
- Lumo answers with the tickets to accept (one you clicked, or one auto-accept
  picked) and the extension sends the same `POST /tickets/{id}/assign` as the
  web app's Accept button.

When the tab is closed, nothing happens.

## Install

1. In Lumo: Settings → WhaTicket → **Set up browser extension**. This copies the
   extension to a folder and registers the native-messaging host with your browsers.
2. Open `chrome://extensions` (Edge: `edge://extensions`) and turn on **Developer mode**.
3. **Load unpacked** and pick the folder Lumo shows.
4. Keep a whaticket.com tab open and turn on the WhaTicket pill.

The extension id is fixed by the `key` in `manifest.json`
(`jcdddeeehgafiakcgaabpiocfdijekce`); only that id may start Lumo's host.

## Tests

```
node --test extensions/whaticket/background.test.js
```
