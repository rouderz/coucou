// Mochi's voice (the macOS VoiceOutput): reads chat replies aloud with the
// system's own voices (speechSynthesis), in the interface language. Push-to-talk
// lives in Rust (src-tauri/src/voice.rs). "Hey Mochi" (an always-listening mic
// with an on-device keyword detector) has no equivalent here.

import { State } from "./state";
import { language } from "./i18n.ts";

function pickVoice(lang: string): SpeechSynthesisVoice | null {
  const voices = window.speechSynthesis?.getVoices() ?? [];
  return voices.find((v) => v.lang.toLowerCase().startsWith(lang) && v.localService)
    ?? voices.find((v) => v.lang.toLowerCase().startsWith(lang))
    ?? null;
}

/** Plain text for the ear: no markdown marks, no URLs read letter by letter. */
export function speakable(text: string): string {
  return text
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/[*_#`>]+/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 1200);
}

export function speak(text: string) {
  if (!State.settings.speakReplies || !("speechSynthesis" in window)) return;
  const said = speakable(text);
  if (!said) return;
  window.speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(said);
  const lang = language();
  u.lang = lang === "es" ? "es-ES" : "en-US";
  const voice = pickVoice(lang);
  if (voice) u.voice = voice;
  u.rate = 1.05;
  window.speechSynthesis.speak(u);
}

export function stopSpeaking() {
  if ("speechSynthesis" in window) window.speechSynthesis.cancel();
}
