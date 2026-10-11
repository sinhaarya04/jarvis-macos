# JARVIS for macOS

A background Mac assistant with a native menu-bar toggle, local speech recognition, Claude or local Qwen inference, a two-clap office greeting, and explicit Mac controls. It has no dashboard, Dock icon or window on launch. Personal development build for Apple Silicon. Paid Claude and TypeSafe APIs are optional; this installation uses Claude Sonnet 4.6 and Jev. Secrets stay in macOS Keychain.

## Run

```sh
bash scripts/setup-local.sh
make check
bash scripts/install.sh
```

The installer places the app in `~/Applications/JARVIS.app` and the verified speech model in `~/Library/Application Support/JARVIS/models/`. It uses Ollama at `127.0.0.1:11434`. Ollama's existing models and account configuration are preserved; JARVIS only permits the named local Qwen models and rejects cloud-model metadata.

Launch JARVIS once, then click its menu-bar waveform and enable **JARVIS listening**. Allow microphone access if macOS asks. With direct listening enabled, say a command and pause; no keypress or wake word is required. **“Hey Jarvis, Aryan here to start working”** and the **Office mode** menu item run the same briefing. Wake-word-only mode is optional in Settings.

Hands-free mode uses a lightweight speech/silence detector and local Whisper transcription to recognize the wake phrase. It is not a dedicated always-on wake-word neural network: audible background speech also needs local transcription before it can be ignored. It does not send that speech to a server or retain ignored transcripts. Quiet periods do not invoke Whisper or the language model. Speech segments finish after roughly 0.85 seconds of silence; segments exceeding 12 seconds are discarded rather than executing a truncated command. This adds transcription latency and needs real-microphone testing in your room.

The icon changes to a microphone while listening and an ellipsis while working. macOS also shows its microphone privacy indicator. Listening pauses during JARVIS's speech, transcription, task execution, sleep, and locked sessions. This version cannot hear a spoken interruption while it is busy or replying. **Option Escape** or **Stop** in the menu bar cancels work. **Option Space** remains an optional manual-recording shortcut; press again to finish (20-second maximum). All temporary recording/transcription files are deleted after use.

The menu also provides **Settings**, **Type a command**, **Test greeting**, **Read last response**, and **Copy last response**. These are native Mac controls; settings or the optional command dialog appear only when explicitly chosen. Voice activation and claps do not bring JARVIS to the front. Settings include an optional **Start at login** switch. Listening preferences persist after you enable them. If a development update resets microphone permission, macOS may ask again to restore your previously enabled listening modes.

**Voice:** the installed macOS Samantha voice with a light local metallic/modulation effect, for both the greeting and ordinary replies. No paid voice service or additional model download. The greeting is prepared in advance; replies are rendered on demand. Temporary speech text/audio is removed after playback or cancellation. Native female speech is the fallback if audio rendering fails.

Enable **JARVIS listening** in the menu bar for **“Welcome to the office, boss.”** and Office mode. The second detected clap directly starts a preloaded local greeting, before app launching, network calls, transcription or model loading. It rearms automatically after a four-second cooldown and once speech/tasks finish. It shares one microphone stream with hands-free listening and pauses during recording, speech output, tasks, and sleep. Keep **Speak replies** on to hear the greeting. Real microphone sensitivity still needs calibration on your setup. The one menu toggle controls both claps and hands-free listening.

## Commands

| Command | Behavior |
| --- | --- |
| `test greeting` | Speaks the welcome message locally |
| `open Claude in Chrome` | Opens Claude in existing Chrome |
| `open Outlook` | Opens Outlook; uses Outlook web when the app is absent |
| `open Notes` | Opens an installed application |
| `switch to the WSJ tab` | Focuses one matching Chrome tab; rejects ambiguous matches |
| `make a note called Ideas: Try a walking meeting` | Creates an Apple Note |
| `type this: Thank you for the update` | Pastes into the previous app's editable field; preserves the clipboard and never presses Send |
| `send an iMessage to Alex: I will arrive at six` | Resolves a contact and submits the explicit message; asks which address when ambiguous |
| `summarize this email` | Summarizes selected text from the previous app |
| `summarize this page` | Reads visible text from the current Chrome tab |
| `summarize: [text]` | Summarizes supplied text with the selected model |
| `browser: find the pricing page and summarize it` | Local model chooses from real links on the current site, for at most three navigation steps |
| `office mode` / `brief me` | Greeting, live market briefing, Outlook, connected inbox previews, and WSJ |

Ordinary conversation uses the model selected in Settings. Claude streams short sentences into the approved 210-word-per-minute robotic Samantha voice. Local Qwen remains available as an offline choice. Conversation output cannot execute tools. The initial browser agent only reads pages and follows permitted same-host HTTPS links; it cannot click arbitrary buttons, fill forms, or submit messages. It uses a small native adapter, not the Browser Use Python package. Browser Use's Ollama support was reviewed; its larger action schema and dependencies are deferred pending quality/resource testing. Direct Mac commands remain available when the model is unloaded.

## Connections

**Microphone:** requested when you first record or enable claps.

**Automation:** macOS asks when JARVIS first controls Chrome, Notes, or Messages. Grant the apps you want to use.

**Accessibility:** enable JARVIS in System Settings → Privacy & Security → Accessibility for selection reading and typing. Focus the destination field before opening JARVIS. Secure password fields are excluded.

**Chrome/WSJ:** use your existing signed-in Chrome profile. Enable Chrome → View → Developer → Allow JavaScript from Apple Events for page reads and the browser agent. JARVIS uses visible text; subscription access, loading state, and website restrictions may limit what is available. It does not bypass access controls. Source links and truncation notices appear in the conversation. Homepage summaries may only cover headlines, not full articles.

**Microsoft 365:** open Settings and enter an organization-approved Entra public-client application ID. The app must allow device-code/public-client sign-in and delegated Microsoft Graph `Mail.Read`; JARVIS also requests `offline_access`. The current build uses the `organizations` authority, so the registration must support organizational accounts across tenants. A single-tenant registration needs a tenant-specific authority adaptation. Admin consent may be required. No client secret is used. Refresh tokens are stored in macOS Keychain. Disconnect removes the local credential.

The briefing reads up to five unread **message previews** from the last seven days. It does not mark messages read or send email. Full-message selection is available through `summarize this email`; automatic full-thread retrieval is a future increment. If the mailbox is not connected, Office mode opens Outlook and records setup instructions without reading a long warning aloud.

**Messages:** sign into iMessage in Apple's Messages app. Sending requires an explicit command with recipient and body. Multiple matching contacts/addresses are shown for selection. Submission is distinguished from verified delivery. No live messages are sent by the test suite. If a send times out, check Messages before retrying.

## Resource behavior

- Installed model: `claude-sonnet-4-6`; faster `claude-haiku-4-5-20251001` is available in Settings. Local Qwen metadata is verified before local requests.
- 4,096-token context, 256-token response ceiling, thinking disabled, one assistant task at a time.
- Models unload after each response; startup may be slower as a result.
- Speech transcription uses whisper.cpp base.en with Metal acceleration and four CPU threads, then exits before language-model inference starts.
- Critical memory-pressure notifications stop local inference; cloud replies remain available. The app never raises system GPU memory limits.
- Microphone audio stays on-device. In Claude mode, requested conversation and summaries go to Anthropic. Jev receives requests or browser excerpts only for intent/link decisions. Market sources and Microsoft 365 require the internet.
- Summaries over 6,000 characters are explicitly labeled as partial. Small-model summaries require checking against linked sources.
- To experiment with the larger local option later: `ollama pull qwen3.5:2b`, then select it in Settings. It has not been enabled by default.

## Development and verification

`make build` produces `dist/JARVIS.app`. `make check-audio` exercises the hands-free capture/transcription pipeline using synthetic speech without recording the microphone or executing an app action. `make check` runs deterministic tests, Swift type checking, plist validation and shell syntax checks. `python3 scripts/benchmark.py` runs synthetic model prompts and records local performance without reading real emails. Benchmark files record their limits; Ollama's allocation figures are not total system RAM.

The app is built directly with `swiftc` and system frameworks. Build requires Apple's Command Line Tools. Runtime setup uses free Homebrew packages and public model weights. See [verification notes](docs/VERIFICATION.md) for what has actually been tested and what still needs live permission/account testing.

## Components and references

- [Ollama](https://github.com/ollama/ollama) — local model serving, MIT.
- [Qwen3.5](https://huggingface.co/Qwen/Qwen3.5-0.8B) — model weights, Apache-2.0.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — local transcription, MIT.
- [FreeFlow](https://github.com/zachlatta/freeflow) — reviewed for native dictation design. This initial app uses new implementation code and does not vendor FreeFlow source.
- [Laya-CoreML](https://github.com/mizorewww/laya-coreml) — reviewed as an optional short-intent classifier; see [assessment](docs/LAYA_COREML.md). Not bundled.
- [Browser Use](https://docs.browser-use.com/open-source/supported-models) — reviewed for local browser-agent compatibility; not bundled.

This is a local personal build, ad-hoc signed. Continuous voice interruption, a dedicated wake-word model, rich browser form control, and verified iMessage delivery are not implemented in v0.2. The current wake phrase is recognized through local speech transcription.

## Version 0.3 additions

The compact native command bar appears beneath the menu bar while you speak or JARVIS works. It does not take keyboard focus. Optional Apple Speech recognition provides live text **on-device only**; macOS Speech Recognition permission is required. Whisper still verifies the finished utterance locally. If live recognition is unavailable or permission is denied, the final Whisper transcript is shown after a pause. Continuous spoken interruption is still unavailable.

A clearly recognized request such as “Jarvis, can you open the Notes app and…” can open a known app after a 450 ms stability delay while you continue speaking. This early path only opens apps. Notes, typing and sending wait for the complete command. “Open the Notes app and create a note: buy coffee” is supported. Partial transcripts can change; early opening is reversible but not a guarantee of perfect intent recognition.

Say “Jarvis, give me Indian market news”, “what is the Bitcoin price”, “interest rate updates”, or “brief me”. Public RSS headlines, Yahoo index quotes, Coinbase BTC spot, and official Fed/RBI rates are fetched concurrently without waiting for an LLM. Quote timestamps and publication dates are retained; stale/missing sources are omitted or explicitly unavailable. RSS provides a headline digest, not full WSJ subscriber articles or a prediction. Full signed-in articles remain available through “summarize this page”.

The TypeSafe key can be updated in Settings. Jev handles flexible app/news intents and chooses among observed browser links; all outputs are validated. The browser-use/jev-ultrafast repository was reviewed at commit `1231850a0bf1a0c0341fe408ef1668dbbfdfac46`. Its full form/checkout executor is **not** connected to JARVIS yet; this version uses a native Mac adapter. Restaurant booking and food ordering are not implemented.

## Version 0.3.1 command fixes

With **Accept commands without saying Jarvis** enabled, the listening toggle accepts direct speech. This preference was explicitly requested and enabled for this installation. Turning listening off stops capture. Live text now shows direct speech; recognized opening/search commands can execute after a stable pause without waiting for Whisper. Messages, notes and typing still require a completed audio segment.

“Can you open Chrome and open Instagram?” runs two opening actions. Instagram, YouTube, Gmail and other known websites open in Chrome, and explicit HTTPS domains also work. “Open Instagram in Google Chrome”, “open Chrome and Instagram”, and “open Chrome and search for coffee shops” are supported. Literal message/note bodies are never split into actions. Up to four explicit opening/search clauses are supported.

## Version 0.4: start-work briefing and Instagram

The small black command bar uses native Liquid Glass on macOS 26 and translucent material on older systems. It stays compact while idle and expands for a transcript. Its indicator distinguishes active listening from paused input. Stopping a reply restores an opted-in listener after a short delay.

Say **“Hey Jarvis, Aryan here to start working.”** JARVIS plays “Welcome to the office, boss,” adds a greeting based on the Mac's local hour, then fetches U.S./Indian indices, Fed/RBI rates, Bitcoin, and up to five market headlines published within the past 12 hours. This is an explicit lookback window, not measured sleep tracking. Quotes retain source timestamps and may be delayed; their previous-session change is not labeled an overnight return. The menu and voice command call the same routine. **“Give me the news”** and **“latest headlines”** fetch just the dated headline digest. News comes from WSJ, CNBC and The Economic Times feeds, with source links available via Copy last response. Missing feeds and insufficient recent stories are reported honestly.

Instagram uses the existing signed-in Chrome profile and requires Chrome's “Allow JavaScript from Apple Events” setting plus macOS Chrome Automation permission:

- **“Open Vandita Bagga on Instagram.”** Search by name, or use an explicit @handle. If several accounts match, JARVIS enumerates the handles and accepts a spoken number or handle. Confirmed name-to-handle choices are stored locally.
- **“Message her.”** Refers to the opened profile and asks for message text.
- **“Draft a message: Hi, how are you?”** Places the exact text in the correct composer without sending. **“Send it”** submits that pending draft.
- **“Send her a message saying I'll be there at six.”** Composes and submits the literal user-supplied text. Pronouns and drafts expire after five minutes and clear on Stop/new profile lookup.

Jev selects among compatible observed controls when more than one is available. Only profile search, profile opening, message composition and an explicit send are implemented here. It cannot choose arbitrary JavaScript or selectors, switch recipients, overwrite an existing draft, or automatically retry a submission. The draft and conversation header are checked again immediately before sending. A cleared composer confirms submission only; recipient delivery is not claimed. Suggestion/generation from conversation history, arbitrary website forms, food ordering and checkout remain unimplemented.
