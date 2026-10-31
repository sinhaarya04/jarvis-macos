# Verification — September 22, 2026

Personal development build on an Apple M3 MacBook Pro, 8 GB unified memory, macOS 26.2. Tests use synthetic content. No test messages were sent and no real mailbox was read by these tests.

## Immediate clap greeting update (0.2.1)

The welcome is rendered once using an installed macOS voice and packaged as approximately two seconds of local audio. JARVIS prepares its audio player at startup. Office mode calls playback synchronously before scheduling browser, mail or model work. Later spoken responses queue behind the greeting. Clap activation now rearms automatically after a four-second cooldown; monitoring still waits for speech/tasks to finish.

The microphone-buffer test verifies that the second synthetic clap produces a clap event with no speech segment or transcription wait. Actual room pickup and audible speaker output require live confirmation. The menu includes Test greeting to distinguish an output problem from a clap-detection problem.

For a bounded local diagnostic run: `bash scripts/install.sh --test-greeting --diagnose-audio`. This plays one greeting on launch and records only microphone amplitude metrics in macOS's local log for the first 30 seconds, plus monitor/playback state events. It does not save microphone audio or transcripts for the diagnostic. Normal launches do not emit amplitude metrics or play a startup greeting. These diagnostic flags are optional development controls.

## Passed

- `make check`: 50 checks covering command parsing, literal dictation/message bodies, clap timing/noise/echo/cooldown, local-only model policy, browser link restrictions, source truncation, literal AppleScript arguments, cancellation, wake phrase matching, silence segmentation and rejection of speech cut off by the duration cap. Swift type checking, plist and shell syntax validation also passed.
- `make check-audio`: generated “Jarvis, open Claude in Chrome” using macOS speech into a file. Passed that audio through the actual microphone-buffer processing code, speech/silence gate, WAV writer, sample-rate conversion, whisper.cpp, wake-phrase extraction and command parser. Result: `Jarvis, Open, Claude, and Chrome.` → `open("Claude")`. The test does not execute that action. The latest run took **1.16 seconds** for conversion/transcription, excluding recording time and the silence wait. Temporary captured audio was removed.
- Earlier synthetic speech trial: 11.39 seconds on CPU without vocabulary hints, versus 1.96 seconds with Metal and hints. These are individual samples, not representative live-microphone benchmarks.
- The app builds as a native, ad-hoc signed macOS bundle. The background revision contains no dashboard. Its only window constructor is invoked by the explicit Settings menu action; the optional typed-command action uses a native dialog. Neither voice nor claps requests a JARVIS window.

## Local language model measurements

Version 0.2.0 was installed at `~/Applications/JARVIS.app`, restarted, and its running process was verified. `codesign --verify --strict` passed. Live visual menu verification remains limited as described below.

Raw results: [benchmark-qwen3.5-0.8b.json](benchmark-qwen3.5-0.8b.json).

| Synthetic case | Total time | First token | Output tokens/sec |
| --- | ---: | ---: | ---: |
| First conversation | 64.57 s | 59.65 s | 4.64 |
| Email summary | 13.07 s | 8.81 s | 10.98 |
| Adversarial source | 5.34 s | 4.32 s | 36.03 |

The initial run included substantial cold loading while development/Metal compilation and other desktop apps were active. The machine already had substantial swap use. These measurements do not isolate JARVIS's effect on responsiveness or battery life. Ollama reported **1,086,932,908 bytes** allocated for the model; this is not total app/system memory. Unified GPU memory is not an additional independent allocation to add to that number. Models unload after responses.

The small model summarized the benign synthetic email, but the adversarial-source test inaccurately attributed an embedded malicious instruction to the user. No action ran: summary/chat output cannot execute Mac tools. Summary faithfulness needs improvement and broader evaluation; the current 0.8B model should not be treated as a reliable autonomous decision maker.

## Still needs live testing or setup

- Native UI automation timed out when selecting JARVIS. The user supplied a screenshot of the previous dashboard; automated visual verification of the replacement menu remains incomplete.
- Real microphone levels, wake-phrase accuracy in this room, clap sensitivity, background speech/TV behavior, latency and battery impact. Synthetic speech is not evidence of real-world wake-word reliability.
- macOS microphone, Contacts, Accessibility and app Automation permissions. The build does not bypass them. Native prompts may recur for an ad-hoc signed development app after rebuilding.
- Chrome page reading requires its “Allow JavaScript from Apple Events” setting. Browser navigation and signed-in WSJ extraction are not yet verified end to end.
- Microsoft 365 requires an approved public-client application and sign-in. No account credentials were provided. Current automatic mail retrieval is limited to five recent unread previews.
- Notes creation, dictation focus/clipboard behavior, tab switching, contact resolution and iMessage submission require live integration checks. No delivery is claimed or automatically retried.
- Sleep/lock/wake recovery and optional start-at-login need user-session validation. Launch-at-login is not enabled automatically.

## Current limits

Hands-free wake recognition uses local Whisper after speech segmentation, not a dedicated tiny wake-word model. Ambient speech may consume transcription resources even when ignored. Speech input pauses during model work, actions and spoken output, so spoken interruption is unavailable then. Use the menu-bar Stop command or Option Escape; listening can be disabled in the menu bar. The JARVIS listening toggle now disables both modes.

Laya-CoreML and the Browser Use package are not bundled. The native browser adapter is limited to observed same-host HTTPS links and bounded steps; it does not fill forms or send messages. Link filtering is a guardrail, not proof that every website's GET endpoint is free of side effects.

## Version 0.3 verification (September 22, 2026)

- User approved paid API use and reuse of the Tigress Anthropic key. Its configured Sonnet model is `claude-sonnet-4-6`. No credentials are included in source control or diagnostic output.
- Synthetic direct API checks: Sonnet first text 1.47 s / completion 1.71 s; Haiku first text 0.70 s / completion 0.73 s. These are single short text requests, not microphone-to-speaker timings or latency guarantees.
- TypeSafe Jev 1.13.0 selected `open_notes` with probability/confidence 1.0 in a 0.94 s synthetic API request; no app was opened by this check.
- Actual Swift MarketService fetched the Indian digest in 3.92 s and full global/Indian/rates/BTC digest in 5.67 s. All requested source families returned data in those runs. Public providers may throttle or change schemas.
- Apple Speech reports on-device English recognition is supported on this Mac. Live microphone previews require the app's macOS Speech Recognition permission. Partial previews do not replace final Whisper verification for consequential commands.
- Keychain access from the installed app, new HUD appearance and updated audio checks are recorded after installation below.

### Installed v0.3.0 checks

- `make check`: 71 core checks + 14 service checks passed, with Swift type checking, plist validation and shell checks. Automated tests do not call paid APIs. Service tests cover stale/future quotes, previous-session changes, RSS filtering, Claude interrupted streams and invalid/low-confidence Jev outputs.
- `make check-audio`: clap bypass passed; synthetic hands-free phrase transcribed and routed correctly in 2.11 s during development load; robotic female rendering remained intelligible. No real app action executed.
- Installed at `~/Applications/JARVIS.app`; strict code-signature verification passed. Actual installed app successfully read both keys from Keychain: Claude replied to a synthetic hearing check in 3.74 s; Jev selected Notes in 0.89 s. These are complete request timings, not first-token or end-to-end voice measurements.
- Temporary TypeSafe import file was deleted after Keychain import; source scan found no embedded credentials.
- CUA inspected the new native command bar and its rendered screenshot: microphone glyph, transcript, status and Stop control visible, no dashboard.
- System Settings → Privacy & Security → Speech Recognition visibly shows JARVIS **on**. The earlier service diagnostic ran before permission was granted and recorded false. No privacy toggle was changed by the assistant. Live microphone accuracy and early app-opening behavior still need user-room testing.

## Version 0.3.1 regression verification

- User explicitly chose direct commands while listening is on; `directListening` is persisted and selected during installation. Wake-word mode remains optional.
- 89 core checks and 14 service checks passed. Added regression cases for the exact “Can you open Chrome and open Instagram?” utterance, browser qualifiers, chained search, full Chrome names, URL handling, and literal message/note bodies.
- New synthetic audio reproducing the exact Chrome/Instagram phrase transcribed as “Can you open Chrome and open Instagram?” and routed into two separate opening actions without a wake word. The test does not execute those actions or validate room acoustics. Existing hands-free synthetic recognition took 2.13 s; clap and robotic-voice checks passed.
- Live opening/search intents can now use Apple recognition directly after a stable pause, independently of the amplitude gate and without a second Whisper pass. Notes/messages still wait for a completed utterance. UI and installed-app checks follow below.
- Installed version 0.3.1 and verified its strict code signature. Persisted direct listening and hands-free flags are both enabled. The running app's local state-only audio log recorded hands-free live commands accepted after speech pauses at 01:59:24 and 01:59:45, followed by successful reply playback and microphone monitoring resumption. Logs do not contain the utterances, so these events do not verify a specific command's browser outcome.
- Native UI inspection of the accessory app timed out during the final Chrome/Instagram integration check. The exact phrase is verified through synthetic audio and command routing; a controlled live browser outcome for that phrase remains unverified. No actions were issued through an alternative UI-control mechanism to bypass that limitation.

## Version 0.4 checks

- 116 core checks and 17 service checks passed, including the exact spoken start-work phrase, generic news routing, Instagram pronouns/drafts/explicit sends, recipient choices, local-hour greetings and the 12-hour news boundary.
- 13 offline DOM-fixture checks passed for literal input, existing-draft protection, exact recipient/body checks, changed recipient headers, stale/covered controls, offsite rejection and single-use sends. These fixtures never open a browser or send a message.
- Synthetic audio recognized “Hey Jarvis, Aryan here to start working.” and dispatched the same briefing command as the menu. Existing speech/clap/robotic-voice checks also passed; ordinary synthetic transcription took 0.97 seconds in this run. This is not a live-room benchmark.
- The actual MarketService fetched all quote/rate families plus five dated headlines from the past twelve hours in 1.56 seconds. Headline sources in that run included WSJ, CNBC and The Economic Times.
- A live CUA inspection searched Instagram for the requested name, found several accounts, and opened @vandita.bagga only after the user selected that handle. Its Message control opened a composer whose profile-header link identified the same recipient. No message was typed or sent in this live inspection; these were CUA observations of Instagram, not proof that the installed JARVIS executor completed the workflow.
- At the user's clap-failure report, no JARVIS process was running. After reopening, state-only logs confirmed both clap and hands-free monitoring. The rebuilt copy then reported microphone permission unavailable; macOS permission handoff and final installed-app integration results are recorded below when available.

## Issue #1 and #2 regression checks (October 31, 2026)

- `make check` passed: 135 core checks, 44 service checks, and 13 offline browser-control checks, plus whole-app Swift type checking, plist validation, shell syntax checks, and `git diff --check`.
- The parsed request “send a message to Sam saying running late” cannot select a lone Samantha Jones for automatic sending. Exact given/family/full names, case and whitespace normalization, partial names, and multiple addresses are covered. The existing menu shows pending choices whenever the recipient list is nonempty, including a single uncertain result.
- Key-import fixtures cover optional `export`, spaces/tabs, quoted and unquoted values, trailing comments, CRLF, duplicate assignments, malformed quotes, and unsupported variable/command values. Errors do not echo the synthetic key.
- These checks use synthetic recipients and keys. They do not read Contacts, write Keychain, call paid APIs, or send real messages. Live message delivery and actual credential import were not exercised for these fixes.
