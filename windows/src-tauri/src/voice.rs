// Push-to-talk (the macOS VoiceInput): one spoken question, turned into text by
// the system's own speech recognition. Windows has it built in (WinRT); Linux
// has none, so the button isn't offered there. Mochi reading replies aloud is
// the page's own speechSynthesis (src/core/voice.ts).

/// Listens until the user stops talking and returns what they said.
#[cfg(windows)]
pub async fn listen() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(listen_blocking)
        .await
        .map_err(|e| e.to_string())?
}

#[cfg(windows)]
fn listen_blocking() -> Result<String, String> {
    use windows::Media::SpeechRecognition::{SpeechRecognitionResultStatus, SpeechRecognizer};
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

    // WinRT needs the thread in the multithreaded apartment; already being in
    // one is fine.
    unsafe {
        let _ = RoInitialize(RO_INIT_MULTITHREADED);
    }
    let words = |e: windows::core::Error| {
        let code = e.code().0 as u32;
        match code {
            // The user turned off online speech recognition (needed for dictation).
            0x80045509 => "Turn on online speech recognition: Windows Settings → Privacy & security → Speech.".to_string(),
            // No microphone, or access denied.
            0x80070005 => "Coucou can't use the microphone: allow it in Windows Settings → Privacy & security → Microphone.".to_string(),
            _ => format!("Speech recognition failed: {}", e.message()),
        }
    };
    let recognizer = SpeechRecognizer::new().map_err(words)?;
    let compiled = recognizer.CompileConstraintsAsync().map_err(words)?.get().map_err(words)?;
    if compiled.Status().map_err(words)? != SpeechRecognitionResultStatus::Success {
        return Err("Speech recognition isn't available for this language.".into());
    }
    let result = recognizer.RecognizeAsync().map_err(words)?.get().map_err(words)?;
    let text = result.Text().map_err(words)?.to_string();
    let text = text.trim().to_string();
    if text.is_empty() {
        Err("I didn't catch that. Try again.".into())
    } else {
        Ok(text)
    }
}

#[cfg(not(windows))]
pub async fn listen() -> Result<String, String> {
    Err("Speech recognition isn't available on Linux.".into())
}

/// Whether push-to-talk is offered on this system.
pub fn can_listen() -> bool {
    cfg!(windows)
}
