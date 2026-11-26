# Changelog

## Unreleased

- **Automations**: run Claude Code, Codex or any command with your prompt or skill on every meeting
  transcript (named speakers or not), after each meeting or on demand. Shows each run's summary,
  changed files and cost per meeting. Undersay detects which agents are installed and signed in.
- **New sidebar**: Record, Today, then Library (Meetings, Dictations, People), Insights (Coach,
  Statistics) and Automations, all as plain rows with counts. **Today** replaces Home: today's meetings,
  open commitments, dictations and automation runs. "Voices" is now **People**.
- **Coach** (sidebar): one habit to focus on each week, picked against your own history; airtime,
  questions, cut-ins and hedge words; commitments you made and ones others made to you; a tone check
  using Apple's on-device sentiment model; and per-meeting feedback from Apple Intelligence, only when
  you ask, verified against your actual words and saved with the meeting.
- Paragraph breaks now come from a small model (pause relative to your own rhythm, transition words,
  topic shift from on-device sentence embeddings, paragraph length) instead of a fixed pause. Short
  dictations and thinking pauses stay one paragraph.

## 0.9.1

- **Murmur is now Undersay.** Several other Mac dictation apps share the old name. On first launch your
  transcripts, voice prints, dictation history and settings move over automatically. macOS treats the
  renamed app as new, so allow Microphone and Accessibility once more.

- Statistics page (sidebar tile "Statistics"): words dictated and time saved, latency histogram with
  median, p95 and real-time factor, speaking pace, a weekday × hour heatmap, top apps, meeting talk share,
  the people you meet most, an engine room (chip, model, embeddings, disk and memory) and fun facts.
- Smart formatting for dictation, rule-based and instant: email greetings and sign-offs, paragraph breaks
  from real pauses (measured in the audio), numbered lists from "First… Second… Third…", and the spoken
  commands "new line", "new paragraph" and "bullet point". Single-line fields stay on one line.

## 0.9.0 — first public beta (as Murmur)

- Hold **fn** to dictate into any app; double-tap to lock it on, tap once to finish; esc cancels
- On-device transcription with Parakeet on the Neural Engine (around 100 ms for a typical sentence)
- Meeting recording of mic and call audio through a Core Audio process tap, with a live transcript
- Speaker diarization and local voice prints that recognise people across meetings
- Software echo removal for meetings without headphones
- Optional on-device meeting summaries with Apple Intelligence
- Dictation timeline with app icons, a meetings gallery and a voices library
- Liquid Glass interface with sounds and trackpad haptics
