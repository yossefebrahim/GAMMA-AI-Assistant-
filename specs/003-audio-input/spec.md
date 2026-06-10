# Feature Specification: Audio Input — Voice Understanding

**Feature Branch**: `003-audio-input`

**Created**: 2026-06-10

**Status**: Draft

**Input**: User description: "Audio (voice) input for the on-device Gemma chat — the third feature slice, building on 001 (model download + streaming chat) and 002 (single-image input). A mic button in the chat composer, visible only when the active model can understand audio (capability-driven gating, never hardcoded). Tap to record with a visual recording state in the design-system style; tap again to stop; clip length is capped by the app. The recorded clip appears as a removable preview chip in the composer (like the image preview), at most one attachment per message. Send streams an assistant reply about the audio content, reusing the existing streaming path; follow-up turns keep referring to the clip. Audio persists in conversation history like images do (file path + metadata, never BLOBs); deleting a conversation removes its audio. Mic permission is requested on first use with graceful denial states; declining never blocks text chat. Out of scope: live transcription display, voice output (TTS), wake word, background recording. Phase 0 spike (spike-findings.md) verified audio grounding works end-to-end on the reference device."

## Clarifications

Three product decisions had no single obvious answer. Each was resolved with the documented
provisional default so this spec is complete and testable; **all three are flagged for review**
and can be changed before implementation begins.

- **Q1 — Maximum clip length**: the model runtime enforces no cap, so the app must own one.
  *Provisional answer: 30 seconds.* Rationale: audio consumes roughly 6 context tokens per
  second, so a 30 s clip (~190 tokens) fits comfortably inside the conversation's context budget
  alongside history; measured memory and latency at 7 s extrapolate safely to 30 s; and 30 s
  matches familiar voice-note conventions. A longer cap (60 s+) would crowd out conversational
  history and carries unmeasured memory/latency risk on the baseline device.
- **Q2 — Pre-send playback**: can the user listen to the clip before sending, and replay clips
  from history? *Provisional answer: playback of the pending clip in the composer preview only;
  history shows a static audio chip (duration label, no playback) in this slice.* Rationale:
  pre-send confirmation is the audio analogue of seeing the image preview (the user must be able
  to verify what they recorded); in-history playback adds a player surface to every bubble for
  marginal value this slice and is a natural later enhancement (Lean Scope).
- **Q3 — Can one message carry both an image and an audio clip?** *Provisional answer: no — at
  most one attachment per message, of either kind; attaching one kind replaces a pending
  attachment of the other kind, with a brief note.* Rationale: combined image+audio in a single
  turn is unverified on the runtime (the spike tested audio alone), and one-attachment-per-message
  preserves the established 002 mental model. Relaxing this later is additive.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Record a voice clip and get a reply about it (Priority: P1)

From the chat screen, with an audio-capable model active and mic access granted, the user taps
the mic button in the composer and the app starts recording, showing a clear recording state —
elapsed time counting up and a pulsing indicator in the product's signature style, with the red
accent that is reserved for exactly this kind of live state. The user taps again to stop. The
captured clip appears as a compact preview chip in the composer showing its duration, where the
user can listen back to it, remove it, or record again (replacing it). The user sends the clip on
its own or together with a typed prompt such as "what language is this?". After sending, the
audio chip appears inside the user's message in the conversation, and the assistant replies about
what it heard — transcribing, describing, or analyzing the audio — with the reply streaming in
word-by-word, exactly as text and image replies already do.

**Why this priority**: This is the entire point of the feature — the assistant's second
multimodal capability and its first hands-free input. Everything else (capability gating,
permissions, persistence, caps) supports or protects this core exchange. If only this story
ships, the product gains a complete, demonstrable voice-understanding capability.

**Independent Test**: With an audio-capable model active and mic access granted, record a short
spoken clip, confirm the recording state is visible while recording and the preview chip appears
on stop, optionally add a text prompt, send, and verify the audio chip shows inside the user
message and the assistant's reply about the audio streams in incrementally.

**Acceptance Scenarios**:

1. **Given** an audio-capable model is active and mic access is granted, **When** the user taps
   the mic button, **Then** recording starts and a visible recording state appears (elapsed time
   plus a pulsing live indicator), and the composer's other input affordances reflect that a
   recording is in progress.
2. **Given** recording is in progress, **When** the user taps the stop control, **Then**
   recording ends and the captured clip appears as a preview chip in the composer showing its
   duration.
3. **Given** a clip is previewed in the composer, **When** the user plays it back, **Then** the
   clip is audible in full before sending; **When** the user removes it, **Then** the chip clears
   and no audio is attached to the next send; **When** instead the user records again, **Then**
   the new clip replaces the previous one (still a single clip).
4. **Given** a clip is previewed, **When** the user sends with no text, **Then** the message is
   sent with the audio alone and the assistant replies about the audio.
5. **Given** a clip is previewed, **When** the user sends together with a typed prompt, **Then**
   the message carries both the audio and the text and the assistant's reply addresses the prompt
   in the context of the audio.
6. **Given** a message with audio has been sent, **When** the conversation renders, **Then** the
   audio chip appears inside the user's message and the assistant's reply streams in word-by-word
   rather than appearing only as a single finished block.

---

### User Story 2 - Mic affordance reflects the active model's capabilities (Priority: P2)

The mic button is offered only when the currently active model can understand audio. If the
active model cannot, the button is not shown and the user can still chat normally with text (and
images, if supported). When the user switches models, the mic button appears or disappears to
match the newly active model. Audio already sent in a conversation remains visible in that
conversation's history even if the user later switches to a model that cannot understand audio.

**Why this priority**: Honest, capability-driven affordances are a core product principle — the
UI must never offer an input the active model cannot handle, and the decision must be read from
the model's declared capability data, never hardcoded. This protects the P1 experience across
model changes, but P1 is demonstrable on a single audio-capable model without it.

**Independent Test**: With an audio-capable model active, confirm the mic button is present;
with a model whose capabilities exclude audio (exercised via capability data in tests), confirm
the button is absent while text chat still works; confirm a conversation containing sent audio
still renders its audio chips when an audio-incapable model is active.

**Acceptance Scenarios**:

1. **Given** an audio-capable model is active, **When** the user views the message composer,
   **Then** the mic button is shown.
2. **Given** a model without audio capability is active, **When** the user views the composer,
   **Then** the mic button is not shown and text (and any other supported input) works normally.
3. **Given** the active model changes between audio-capable and not, **When** the switch
   completes, **Then** the mic button appears or disappears to match the now-active model without
   requiring an app restart.
4. **Given** a pending recorded-but-unsent clip exists, **When** the active model becomes one
   that cannot understand audio (genuinely loaded, not merely loading or failed), **Then** the
   pending clip is cleared and the user is told why; text chat continues normally.
5. **Given** a conversation that already contains sent audio, **When** an audio-incapable model
   is active and that conversation is opened, **Then** the previously sent audio chips are still
   visible in place in the history.

---

### User Story 3 - Follow-up questions that keep referring to the audio (Priority: P2)

After the assistant replies about a clip, the user asks follow-up questions in the same
conversation — without re-recording or re-attaching anything — and the assistant keeps referring
to the audio it already heard, answering the new questions in its context.

**Why this priority**: Multimodal conversational memory is what makes the clip feel like a
shared part of the conversation rather than a one-shot lookup. The capability was empirically
verified in the Phase 0 spike (a follow-up answered correctly from audio context alone). It
builds directly on Story 1 but the core capability is demonstrable in a single turn.

**Independent Test**: Send a spoken clip with one question, receive a reply, then send one or
more text-only follow-ups that depend on the audio (e.g., "which animal was mentioned first?");
verify the replies reflect the previously heard audio without re-attaching it.

**Acceptance Scenarios**:

1. **Given** a conversation in which audio was already sent and answered, **When** the user sends
   a text-only follow-up that depends on the audio, **Then** the assistant's reply takes the
   previously heard audio into account.
2. **Given** a conversation containing audio, **When** the assembled context for a follow-up turn
   is inspected, **Then** the earlier audio is included in that context (subject to the model's
   context limits), verifiable independently of reply quality.

---

### User Story 4 - Clear guidance when mic access is not granted (Priority: P2)

The first time the user taps the mic button, the app requests microphone access. If the user has
not granted it — or has permanently denied it — the app explains why it needs the mic and guides
them to enable it, rather than failing silently. If the user declines, text chat continues to
work normally.

**Why this priority**: Without mic access the record flow cannot start, and a silent failure
would read as a broken feature. Honest, actionable guidance upholds the product's
graceful-degradation promise. It is a guard around Story 1 rather than the core capability.

**Independent Test**: With mic access not yet granted, tap the mic button and verify the system
permission request appears; deny it and verify the app explains why access is needed; permanently
deny and verify the app offers a route to system settings; confirm text chat works normally
throughout.

**Acceptance Scenarios**:

1. **Given** mic access has never been requested, **When** the user taps the mic button, **Then**
   the system permission request is shown, and on grant recording starts (or is one tap away).
2. **Given** mic access was denied but can be asked again, **When** the user taps the mic button,
   **Then** the app explains why access is needed and provides a way to grant it, rather than
   silently doing nothing.
3. **Given** mic access was permanently denied, **When** the user taps the mic button, **Then**
   the app explains the situation and guides the user to the system settings where access can be
   changed.
4. **Given** the user declines to grant access, **When** they return to the chat, **Then** text
   messaging continues to work normally with no broken or stuck state.

---

### User Story 5 - Audio conversations persist across restarts (Priority: P3)

The user closes and reopens the app and finds conversations that contain audio intact, with each
clip's chip still shown in place within the message it was sent in.

**Why this priority**: Persistence turns a multimodal exchange into part of the durable history
users rely on. It is expected behavior, but the capability is demonstrable within a single
session, so it ranks below the interactive stories.

**Independent Test**: Send a clip (with and without text), force-quit the app, relaunch, reopen
the conversation, and confirm the audio chip is still displayed in place with its duration, and
the surrounding messages and order are intact.

**Acceptance Scenarios**:

1. **Given** a conversation that contains one or more sent clips, **When** the app is force-quit
   and relaunched, **Then** the conversation, its messages, their order, and each audio chip are
   all present and shown in place.
2. **Given** a restored conversation with audio, **When** the user continues it with a follow-up,
   **Then** the conversation continues normally with the audio still part of its history.
3. **Given** a conversation containing audio is deleted, **When** the deletion completes, **Then**
   the stored audio data is removed with it, leaving no orphaned audio content.

---

### User Story 6 - Honest handling when recording or processing fails (Priority: P3)

If recording cannot start (mic busy or unavailable), is interrupted (call, audio focus loss,
backgrounding), or the device or model cannot process a given clip, the user receives a clear
message — and keeps whatever was safely captured where that is possible — instead of a hang,
freeze, or crash.

**Why this priority**: Audio capture competes with the rest of the system for the microphone,
and audio-grounded inference is resource-intensive on constrained devices. Failing honestly
upholds the graceful-degradation promise. It is a safety net around the happy path.

**Independent Test**: Start a recording and interrupt it (background the app; trigger an audio
focus loss); attempt to record while another app holds the mic; send a clip and stop generation
mid-stream — verifying in each case a clear outcome, no crash, and a usable conversation.

**Acceptance Scenarios**:

1. **Given** another app holds the microphone or the recorder fails to start, **When** the user
   taps the mic button, **Then** the app shows a clear message and the composer remains usable.
2. **Given** recording is in progress, **When** the app is backgrounded or the system takes the
   audio focus (e.g., an incoming call), **Then** recording stops, the audio captured so far is
   kept as the pending clip (when it meets the minimum length), and the user is told recording
   stopped.
3. **Given** a clip the active model cannot process, **When** the user sends it, **Then** the app
   shows a clear message that the audio could not be processed and the conversation remains
   usable, with no hang, out-of-memory crash, or unexplained termination.
4. **Given** an audio-grounded reply is generating, **When** the user activates the stop control,
   **Then** generation halts promptly and any text produced so far is retained, exactly as for
   text-only replies.

---

### Edge Cases

- **Recording reaches the maximum clip length**: recording stops automatically at the cap, the
  captured clip becomes the pending preview, and a brief note explains the limit was reached.
- **Accidental tap (clip too short)**: a clip shorter than the minimum usable length (under
  roughly half a second) is discarded with a brief note rather than attached.
- **User cancels recording**: a discard control during recording (or removing the chip after
  stopping) throws the audio away; nothing is persisted from a cancelled compose.
- **Pending clip when a typed image is attached (or vice versa)**: attaching one kind of media
  replaces a pending attachment of the other kind, with a brief note (one attachment per message,
  Q3).
- **Pending (recorded but unsent) clip when the model flips to audio-incapable**: the pending
  clip is cleared with an explanatory note — but only when the now-active model is genuinely
  loaded and audio-incapable, never because a model is still loading or failed to load (those
  states must surface as loading/error, not as a capability change).
- **Recording attempted while a reply is generating**: recording a clip is allowed while
  generation runs; sending it follows the existing single-generation-at-a-time rule.
- **Device storage full or audio file write fails**: the user gets a clear message and the
  composer returns to a usable state; no partial file is attached.
- **Stored audio file missing or unreadable at render time**: the chip shows a quiet broken-state
  placeholder; the conversation remains usable.
- **Backgrounding the app mid audio-grounded generation**: generation stops, any partial reply is
  retained, and model resources are released without losing the saved message or its audio.
- **Connectivity lost at any point**: no effect — recording, sending, and audio-grounded
  generation all work fully offline.
- **Sending an empty message**: sending remains prevented until there is audio, an image, text,
  or a permitted combination (per Q3, audio+text or image+text, never audio+image).
- **Screen reader users**: recording start and stop are announced; the recording state and all
  audio controls are reachable and labelled.

## Requirements *(mandatory)*

### Functional Requirements

**Recording & composer**

- **FR-001**: When an audio-capable model is active, the message composer MUST offer a mic
  control that starts an in-app voice recording on tap; a second tap stops it. While recording,
  the composer MUST show a visible recording state including elapsed time and a pulsing live
  indicator.
- **FR-002**: Recording MUST stop automatically when the clip reaches the maximum length
  (30 seconds, Q1), keeping the captured audio as the pending clip and informing the user the
  limit was reached. Clips shorter than the minimum usable length (~0.5 s) MUST be discarded with
  a brief note.
- **FR-003**: After stopping, the captured clip MUST appear as a preview chip in the composer
  showing its duration, and the user MUST be able to play it back (Q2), remove it (clearing the
  attachment), or record again (replacing it — never adding a second clip).
- **FR-004**: A message MUST carry at most one attachment: one audio clip or one image, never
  both (Q3). Attaching media of one kind MUST replace a pending attachment of the other kind,
  with a brief note. The user MUST be able to send a message containing the clip alone or the
  clip together with typed text; sending MUST remain prevented only when there is no attachment
  and no text.
- **FR-005**: The user MUST be able to discard an in-progress recording without it becoming an
  attachment, and a cancelled compose MUST leave no stored audio behind.

**Capability-driven affordance**

- **FR-006**: The mic control MUST be shown only when the currently active model can understand
  audio. When an audio-incapable model is active, the control MUST NOT be shown or enabled, and
  all other supported inputs MUST continue to work normally.
- **FR-007**: Whether to show the mic control MUST be determined from the active model's declared
  capabilities (queried as data from the model catalog / active session), not from hardcoded
  per-model conditionals.
- **FR-008**: When the active model changes, the mic control MUST appear or disappear to match
  the now-active model's audio capability without requiring an app restart.
- **FR-009**: A pending recorded-but-unsent clip MUST be cleared, with an explanatory note, when
  the active model becomes one that cannot understand audio — and this MUST occur only for a
  genuinely loaded audio-incapable model, never as a side effect of a model that is still loading
  or failed to load (load failures MUST surface as load errors, not capability changes).

**Microphone permission**

- **FR-010**: Microphone access MUST be requested on first use of the mic control, not at app
  launch.
- **FR-011**: When mic access is denied (but askable), the system MUST explain why the access is
  needed and offer to request it again; when permanently denied, the system MUST explain the
  situation and guide the user to the system settings where access can be changed. Neither state
  may fail silently.
- **FR-012**: If the user declines mic access, the app MUST remain fully usable for every other
  input with no broken, stuck, or crashing state.

**Sending, display & streaming**

- **FR-013**: After sending, the audio chip (with duration) MUST appear inside the user's message
  in the conversation, rendered in place within that message.
- **FR-014**: The assistant MUST reply about the audio content — transcribing, describing, or
  analyzing what it heard — and the reply MUST stream in incrementally, consistent with how text
  and image replies stream, reusing the existing streaming path.
- **FR-015**: While an audio-grounded reply is generating, the stop control MUST be available and
  MUST behave exactly as for text replies: activating it halts further generation promptly and
  retains the text produced so far as the assistant's turn.

**Multimodal conversational memory**

- **FR-016**: Within the same conversation, the user MUST be able to ask text-only follow-up
  questions that refer to a previously sent clip without re-attaching it, and the assistant MUST
  be able to keep referring to that audio.
- **FR-017**: When generating a follow-up reply, the system MUST include the earlier audio in the
  context provided to the model, subject to the model's context limits; this MUST be verifiable
  by inspecting the assembled context independent of reply quality.

**History & persistence**

- **FR-018**: Audio already sent in a conversation MUST remain visible (as chips with duration)
  in that conversation's history even if the user later switches to an audio-incapable model.
- **FR-019**: Conversations that contain audio MUST persist across app restarts, with each clip's
  chip still shown in place within the message it was sent in. Existing conversations from
  earlier versions MUST survive the upgrade untouched.
- **FR-020**: Audio MUST be stored as files in app-private storage with only a reference and
  metadata kept in the conversation database (never the audio bytes themselves), and deleting a
  conversation MUST also remove the audio data stored for it, leaving no orphaned audio content.

**Graceful degradation & errors**

- **FR-021**: If recording cannot start (mic unavailable or held by another app) or fails
  mid-capture (audio focus loss, backgrounding, write failure), the system MUST present a clear
  message and keep whatever was safely captured when it meets the minimum length; it MUST NOT
  hang, crash, or silently discard without explanation.
- **FR-022**: If the device or the active model cannot process a given clip, the system MUST
  present a clear, actionable message that the audio could not be processed, and MUST NOT hang,
  freeze, out-of-memory crash, or terminate without explanation. A processing failure on a turn
  whose current prompt carries no audio MUST NOT be misattributed to audio.
- **FR-023**: The system MUST capture audio directly in the form the active model accepts, so no
  conversion step can fail after recording; a stored clip that is missing or unreadable at render
  time MUST be shown as a quiet broken state, with the conversation remaining usable.

**Privacy, offline & resource discipline**

- **FR-024**: Audio MUST be processed entirely on-device. No audio content (the recording,
  derived data, or the resulting analysis) may be transmitted off the device; the only permitted
  network operation in the product remains the one-time model download.
- **FR-025**: Recording, sending, and audio-grounded generation MUST work with no network
  connection once an audio-capable model is installed.
- **FR-026**: All stored audio MUST reside in app-private (sandboxed) storage protected at rest
  by the platform's device encryption, with no audio written outside the app's private storage.
- **FR-027**: The interface MUST remain responsive while recording, while a clip is being
  prepared for the model, and while a reply is generating; recorder and audio-session resources
  MUST be released when recording ends, on navigation away, and on backgrounding, consistent with
  existing resource rules; audio bytes MUST NOT be retained in memory between turns.

**Accessibility & design**

- **FR-028**: Every new interactive control (mic, stop/discard while recording, the chip's
  play/remove actions, and any permission-prompt actions) MUST have a touch target of at least
  48dp and meet WCAG AA contrast against its background; recording start/stop MUST be announced
  to screen readers and all states MUST be reachable and labelled.
- **FR-029**: The recording state and audio chips MUST follow the design system: monochrome
  surfaces with hairline separation, no gradients or shadows, lowercase microcopy, dot-matrix /
  Glyph-style pulsing motion (never a spinner), elapsed time in the display/mono face — and the
  red accent used for the live recording indicator and stop control, as the design system
  reserves it for exactly these active/recording/stop/error states (the chip's remove control
  stays monochrome).

### Key Entities *(include if feature involves data)*

- **Audio Attachment**: The single voice clip associated with one user message. Has a stored
  reference to the on-device audio file and its format metadata; its duration is derivable from
  the stored data. Bound to exactly one message; removed when that message's conversation is
  deleted.
- **Pending Recording**: The transient clip captured but not yet sent — exists only in the
  composer, holds a reference to a temporary file (never decoded bytes), and is promoted to an
  Audio Attachment only at send. Cleared on remove, replace, send, conversation switch, or
  capability flip.
- **Message (extended)**: A turn within a conversation that, for the user role, MAY now include
  one audio attachment in addition to the existing optional image attachment — but never both at
  once (Q3). Existing message attributes (role, order, timestamp, completion state) are
  unchanged.
- **Model Audio Capability**: The data describing whether the currently active model can
  understand audio, queried to decide whether the mic affordance is shown. Part of the active
  model's broader capability set (alongside image support), not a hardcoded per-model flag.
- **Mic Permission State**: Whether microphone access is granted, denied, permanently denied, or
  restricted — used to drive the explanatory guidance rather than silent failure.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In moderated usability testing with at least 8 participants on supported,
  audio-capable devices, at least 90% successfully record a voice clip and receive an assistant
  reply about it using only on-screen guidance.
- **SC-002**: With an audio-capable model active, the mic control is present in 100% of observed
  sessions; with an audio-incapable model active, it is absent in 100% of observed sessions; and
  on model switch the control updates to match within the model-switch completion, with no app
  restart, in 100% of trials.
- **SC-003**: On the reference baseline device (a current-generation 8 GB arm64-v8a phone, fixed
  in the test plan), for a maximum-length clip the first words of the assistant's reply become
  visible within 15 seconds (median of 5 runs) of the send action, and text continues to appear
  incrementally until the reply completes.
- **SC-004**: Recording start feels immediate: the recording state becomes visible within 500 ms
  of tapping the mic in 95% of attempts, and the elapsed-time display updates at least once per
  second throughout.
- **SC-005**: A previously sent clip is rendered in place (chip with duration) inside its user
  message in 100% of conversations that contain audio, including after switching to an
  audio-incapable model and after app restarts; deleting such a conversation leaves zero orphaned
  audio data.
- **SC-006**: In a conversation with prior audio, text-only follow-up turns include the earlier
  audio in the assembled model context in 100% of trials (subject to context limits), verifiable
  by inspecting the assembled context.
- **SC-007**: When mic access is not granted, 100% of mic-control taps produce either the system
  permission request or an explanatory message with a path to enable access; zero taps result in
  a silent no-op, and text chat remains fully usable in 100% of these cases.
- **SC-008**: In the failure paths (mic unavailable, recording interrupted, unprocessable clip),
  100% of attempts produce a clear message and zero produce a crash, out-of-memory kill, or
  indefinite hang; interruption cases retain the captured audio whenever it meets the minimum
  length.
- **SC-009**: With connectivity disabled after install, a user can record and send a clip and
  receive a reply, and ask at least 3 audio-referencing follow-ups, with zero failures
  attributable to network access and zero network requests carrying audio content (verifiable via
  network monitoring and airplane-mode testing).
- **SC-010**: While recording and while an audio-grounded reply streams, scroll and input
  gestures receive a visible response within 100 ms.
- **SC-011**: Before release, every new interactive element passes a 48dp minimum touch-target
  check and a WCAG AA contrast check, and recording start/stop announcements are verified with a
  screen reader.

## Assumptions

- "Voice understanding" means the assistant interprets audio the user records; it does NOT
  produce spoken output, display a live transcript while recording, or listen for wake words.
  This phase adds audio **input** only, captured in-app (no importing of existing audio files).
- The active default model (Gemma 4 E2B) supports audio input — verified empirically in the
  Phase 0 spike (word-perfect transcription and correct multi-turn follow-up on the reference
  device); capability gating is nonetheless data-driven so the affordance behaves correctly for
  any model that lacks audio.
- Exactly one clip per message, and one attachment per message overall (audio or image, Q3).
- A 30-second cap (Q1) keeps a clip's context-token cost (~6 tokens/second) and memory overhead
  comfortably inside the measured budget on the baseline device; the cap is a product constant
  the app owns, since the runtime enforces none.
- A recorded clip is captured directly in the audio form the model consumes (single-channel
  speech-quality capture), so nothing needs converting after recording; a maximum-length clip's
  file is well under one megabyte, so audio storage is not a meaningful storage concern.
- A clip is copied into app-private storage only at send (a cancelled compose persists nothing),
  retained for the life of its conversation (shown in history, included in context for
  follow-ups), and deleted when its conversation is deleted. At-rest protection relies on
  app-private storage plus platform device encryption, consistent with the existing slices.
- Audio-grounded first-token latency is higher than text-only latency because the clip must be
  encoded before generation; the success-criteria target accounts for this on the baseline device
  (measured: ~4 s to first token for a 7 s clip; the 15 s budget covers a 30 s clip with margin).
- Capability gating, streaming, stop/cancel, conversational memory, persistence, permission
  explainers, and the design language all reuse the patterns established by 001 and 002; this
  feature extends them to audio rather than redefining them.
- There are no user accounts, no cloud sync, and no analytics that capture conversation content
  or audio data, consistent with the constitution.

## Dependencies

- Relies on the on-device model runtime accepting an audio clip alongside text and producing
  output token-by-token grounded in that audio — verified end-to-end in the Phase 0 spike
  (`spike-findings.md`); there is no backend service involved.
- Relies on device microphone access (subject to the platform's permission model) for capture.
- Relies on local on-device storage for persisting audio alongside conversation data, and builds
  on the existing chat, capability, persistence, and resource-management foundations from 001 and
  002.

## Out of Scope

The following are explicitly **not** part of this phase:

- Live transcription display while recording (or any speech-to-text feature surfaced to the user
  as text).
- Voice output (text-to-speech replies).
- Wake-word or hands-free activation.
- Background recording (recording continues only while the app is in the foreground).
- Multiple clips per message, or audio and image together in one message (Q3).
- Importing existing audio files; audio editing or trimming; playback of clips from history
  (composer preview playback only, Q2); playback speed controls.
- Voice calls or live conversation mode.
