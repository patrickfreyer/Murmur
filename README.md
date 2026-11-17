# Murmur

A lightweight, native macOS dictation and meeting transcriber. Everything runs on this Mac.

- **Dictate anywhere with fn**: hold fn (🌐) and speak, then release to insert the text into the focused field in any app. Double-tap fn for hands-free; Esc cancels.
- **Meeting transcription**: records your mic and the call audio (Zoom, Meet, Teams…) through a Core Audio process tap, shows a live transcript, then does a full on-device pass with speaker diarization.
- **Local voice prints**: name a speaker once and Murmur recognises that voice in future meetings, and relabels older ones too. Your own voice is learned from your dictations.
- **Summaries**: optional meeting notes from Apple Intelligence's on-device model.
- **Touch-friendly**: 44 pt targets, Liquid Glass controls, and a floating mic button for dictating from the touch screen.

## Stack

| Piece | Tech |
|---|---|
| Speech-to-text | Parakeet TDT (Ultra / v3 / v2) on the Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| Speakers | pyannote community-1 segmentation + WeSpeaker embeddings + VBx clustering (FluidAudio) |
| System audio | `CATapDescription` process tap + private aggregate device (no screen recording permission) |
| fn key | `CGEventTap` (Accessibility permission) |
| Insertion | Pasteboard + synthetic ⌘V, clipboard restored afterwards |
| UI | SwiftUI on macOS 26+ (Liquid Glass) |

Models download once from Hugging Face on first launch (~0.5 GB) and are cached in `~/Library/Application Support/FluidAudio`. Transcripts, audio and voice prints live in `~/Library/Application Support/Murmur`.

## Build

```bash
Scripts/build-app.sh release --install   # builds, signs and copies to /Applications
swift test                              # unit tests
```

Signing uses an "Apple Development" identity if one is in your keychain, which keeps the Accessibility permission across rebuilds. Without one it falls back to ad-hoc signing, so you have to grant permissions again after each rebuild.

### End-to-end self-test

```bash
swift Scripts/make-test-meeting.swift /tmp/fx-a a
swift Scripts/make-test-meeting.swift /tmp/fx-b b
MURMUR_HOME=/tmp/murmur-test .build/release/Murmur --selftest /tmp/fx-a /tmp/fx-b
```

This transcribes and diarizes meeting A, names its speakers, then checks that meeting B is labelled automatically from the voice prints.

## Setup on first launch

1. Allow **Microphone**.
2. Allow **Accessibility** (to watch the fn key and paste).
3. System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** (recommended).
4. Recording a meeting the first time asks for **System Audio Recording**.
