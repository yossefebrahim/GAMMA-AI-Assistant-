# Feature Specification: First Working Slice — Model Download & Chat

**Feature Branch**: `001-model-download-chat`

**Created**: 2026-06-07

**Status**: Draft

**Input**: User description: "Build the first working slice of the On-Device Gemma Assistant. A first-time user opens the app to a dark-themed home screen that explains the app runs entirely on their device. Because no model is installed yet, they are guided to download the default model. The download shows live progress (percent and size), can be cancelled, and survives the app continuing to run. If the user's device cannot support the model (insufficient memory or unsupported processor architecture), they are told clearly before the download starts rather than after a failure. Once the model is installed, the user lands in a chat screen. They type a message and send it. The assistant's reply appears word-by-word as it is generated, not all at once. While the assistant is replying, a stop control is visible; tapping it halts generation immediately and keeps whatever text was produced so far. The user can send a follow-up message and the assistant remembers the earlier turns in the same conversation. Conversations persist across app restarts. The user can start a new conversation and see a list of past ones. The entire experience is dark-themed by default and works with no internet connection after the model is present."

## Clarifications

### Session 2026-06-07

- Q: How is the default model obtained for download (given "one-time download" and "no
  accounts")? → A: Fetched from an open, redistributable URL with no login or account; a
  one-time in-app license acknowledgment (a checkbox, not an account) is shown before the
  download starts.
- Q: When a conversation exceeds the model's context window, what is sent to the model? → A:
  A sliding window of the most recent turns that fit; oldest turns are dropped from the context
  only, while the full conversation remains stored and displayed.
- Q: How is locally stored conversation data protected at rest? → A: App-private (sandboxed)
  storage protected by the platform's device encryption; no app-level database encryption in
  this slice (deferred as future hardening).
- Q: What can the user do with the input while a reply is generating? → A: Only one generation
  in flight — send is disabled and replaced by the stop control until the reply completes or is
  stopped.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Onboard and install the default model (Priority: P1)

A first-time user opens the app and is met with a dark home screen that explains the
assistant runs entirely on their device — nothing they type will leave the phone. Because
no model is present yet, the screen guides them to download the one-time default model. They
start the download and watch live progress (percent complete and downloaded size against the
total). They can keep using the rest of the app while it downloads, and they can cancel at
any point. When the download finishes, the app confirms the model is installed and takes them
into chat.

**Why this priority**: Nothing else in the product is reachable until a model is on the
device. This story is the gate to the entire experience and is the first thing every new user
encounters.

**Independent Test**: On a fresh install on a supported device, launch the app, follow the
on-screen guidance to download the model, observe live progress, and confirm the app reaches
an "installed / ready" state. Cancelling mid-download returns cleanly to the pre-download
state with no broken model left behind.

**Acceptance Scenarios**:

1. **Given** a fresh install with no model present, **When** the user opens the app, **Then**
   a dark-themed welcome screen explains the on-device/private nature of the app and offers to
   download the default model.
2. **Given** the welcome screen, **When** the user starts the download, **Then** live progress
   is shown as both percent complete and downloaded-of-total size, updating continuously.
3. **Given** a download in progress, **When** the user navigates elsewhere in the app, **Then**
   the download continues and the interface stays responsive.
4. **Given** a download in progress, **When** the user cancels it, **Then** the download stops
   within 2 seconds, any partial data is discarded, and the user is returned to the pre-download
   state.
5. **Given** a completed download, **When** installation finishes, **Then** the app marks the
   model installed and routes the user into the chat screen.

---

### User Story 2 - Send a message and receive a streaming, stoppable reply (Priority: P1)

With the model installed, the user lands on a chat screen, types a message, and sends it. The
assistant's reply appears incrementally — word by word — as it is generated, rather than
arriving all at once. While the reply is being produced, a clearly visible stop control lets
the user halt generation immediately; whatever text was produced up to that moment is kept in
the conversation.

**Why this priority**: This is the core value of the product — actually talking to the
assistant. Streaming output and an always-available stop control are what make on-device
generation feel responsive and under the user's control.

**Independent Test**: Given an installed model, type a message and send it; verify the reply
renders progressively (not in a single block). Trigger stop mid-reply and verify generation
halts at once and the partial text remains visible and saved.

**Acceptance Scenarios**:

1. **Given** an installed model and an empty chat, **When** the user sends a text message,
   **Then** the assistant's reply appears incrementally as it is generated.
2. **Given** a reply that is currently generating, **When** the user activates the stop
   control, **Then** generation halts within 1 second and the text produced so far is preserved
   as the assistant's turn.
3. **Given** a reply is generating, **When** the user scrolls the conversation, **Then** the
   interface remains responsive and does not freeze.
4. **Given** the chat input, **When** the user views the available input options, **Then** only
   text entry is offered (no image, audio, or other input affordances in this slice).

---

### User Story 3 - The assistant remembers earlier turns in a conversation (Priority: P2)

After an initial exchange, the user sends a follow-up message that refers back to something
said earlier. The assistant's reply reflects the earlier turns of the same conversation rather
than treating each message in isolation.

**Why this priority**: A single isolated question/answer is useful, but conversational memory
is what makes the assistant feel coherent. It builds directly on Story 2 and is essential to a
credible chat experience, but the product is still demonstrable without it.

**Independent Test**: In one conversation, establish a fact in the first message, then ask a
follow-up that depends on it; verify the reply uses the earlier context.

**Acceptance Scenarios**:

1. **Given** a conversation with at least one prior exchange, **When** the user sends a
   follow-up that references an earlier turn, **Then** the assistant's reply takes the earlier
   turns into account.
2. **Given** a reply that was stopped early, **When** the user sends a further message, **Then**
   the retained partial reply is still part of the remembered context.

---

### User Story 4 - Persistent conversations and history (Priority: P2)

The user closes and reopens the app and finds their conversations exactly where they left
them. They can start a brand-new conversation, and they can see a list of past conversations
and reopen any one to review its full history. They can delete a conversation they no longer
want.

**Why this priority**: Persistence and a history list turn a one-off chat into an ongoing,
trustworthy tool. It is not required to demonstrate the core chat, so it sits below the P1
stories, but it is expected behavior for any real assistant.

**Independent Test**: Hold a conversation, force-quit the app, relaunch, and confirm the
conversation and its messages are intact and correctly ordered. Start a new conversation,
confirm both appear in the list, reopen each, and delete one.

**Acceptance Scenarios**:

1. **Given** one or more conversations, **When** the app is force-quit and relaunched, **Then**
   all conversations and their messages are present and in the same order.
2. **Given** the chat experience, **When** the user starts a new conversation, **Then** a fresh
   empty conversation begins and the previous one is preserved in the history list.
3. **Given** the history list, **When** the user opens a past conversation, **Then** its full
   message history is shown and can be continued.
4. **Given** the history list, **When** the user views it, **Then** each conversation shows a
   readable label (derived from its first message) and a timestamp distinguishing it.
5. **Given** a conversation in the list, **When** the user deletes it, **Then** it is removed
   from history and its messages are no longer retrievable.

---

### User Story 5 - Honest device preflight and graceful guidance (Priority: P3)

Before any download begins, the app checks whether the device can actually run the model. A
user on a device that lacks enough memory or has an unsupported processor is told clearly,
up front, why the model cannot be installed — instead of letting them wait through a large
download only to hit a crash or out-of-memory failure afterward.

**Why this priority**: This protects users on weaker devices and upholds the product's promise
never to fail in an unexplained way. It is lower priority only because the happy path (a
supported device) must exist first; on supported devices this check simply passes.

**Independent Test**: Simulate an unsupported device (below the memory baseline or a
non-supported processor architecture) and confirm the app explains the limitation and does not
start the download. On a supported device, confirm the check passes silently and the download
proceeds.

**Acceptance Scenarios**:

1. **Given** a device below the supported baseline, **When** the user attempts to download the
   model, **Then** the app clearly explains the limitation (insufficient memory or unsupported
   processor) and does not start the download.
2. **Given** a supported device, **When** the user attempts to download the model, **Then** the
   preflight check passes and the download proceeds.
3. **Given** any preflight outcome, **When** the result is shown, **Then** the app never crashes
   or terminates without explanation.

---

### Edge Cases

- **Connectivity lost mid-download**: the app informs the user the download was interrupted and
  lets them retry/resume without leaving the app in a broken state; no partial file is ever
  treated as a usable model.
- **App process killed mid-download**: on next launch the download resumes (or restarts
  cleanly); the user is never left with a half-installed model.
- **Storage full during download**: the app reports the problem clearly and discards the
  partial download rather than corrupting the model.
- **Stop tapped before any text is produced**: the user's message is kept; the empty assistant
  turn is handled gracefully (no blank or broken bubble).
- **Empty or whitespace-only message**: sending is prevented until there is content.
- **Leaving the chat / backgrounding the app mid-generation**: generation stops, the partial
  reply is retained, and model resources are released without losing saved messages.
- **Connectivity lost during an active chat**: has no effect — generation and history continue
  to work fully offline.
- **Device exactly at the minimum memory baseline**: treated as supported; the download
  proceeds with the default model.
- **Reopening a past conversation and sending a new message**: continues that conversation with
  its remembered context.
- **Deleting the installed model**: returns the user to the onboarding/download state and frees
  the storage it used.

## Requirements *(mandatory)*

### Functional Requirements

**Onboarding & first run**

- **FR-001**: On first launch with no model installed, the system MUST present a dark-themed
  welcome screen that explains the assistant runs entirely on the device and that a one-time
  model download is required.
- **FR-002**: From the welcome screen, the system MUST guide the user to start the default
  model download. The model MUST be fetched from an open, redistributable URL without any user
  account or login; before the download starts, the system MUST show a one-time in-app license
  acknowledgment (a checkbox, not an account).

**Device preflight (graceful degradation)**

- **FR-003**: Before any download begins, the system MUST check the device against the minimum
  supported baseline: a 64-bit ARM (arm64-v8a) processor and at least 8 GB of total RAM (a
  device with exactly 8 GB is supported).
- **FR-004**: If the device does not meet the baseline, the system MUST clearly explain the
  reason (insufficient memory or unsupported processor) and MUST NOT start the download.
- **FR-005**: If the device meets the baseline, the system MUST allow the download to proceed.
- **FR-006**: An unsupported device MUST NOT cause a crash or forced termination; the app MUST
  remain running and display an explanatory message that identifies which baseline check failed
  (insufficient memory or unsupported processor).

**Model download**

- **FR-007**: During download, the system MUST display live progress as both percent complete
  and downloaded-of-total size, refreshing at least once per second while bytes are being
  received.
- **FR-008**: The user MUST be able to cancel an in-progress download at any time; cancelling
  MUST stop the download within 2 seconds and discard any partial data so no unusable model
  remains.
- **FR-009**: The download MUST continue while the user keeps the app open and navigates within
  it, without freezing the interface. (Behavior if the app process is killed mid-download is
  covered in Edge Cases.)
- **FR-010**: On successful completion, the system MUST mark the model installed and route the
  user into the chat experience.
- **FR-011**: If a download fails or is interrupted, the system MUST inform the user and offer
  to retry. A retry MUST either resume from the verified partial download or restart cleanly; in
  no case may a partial or unverified file be treated as a usable model.

**Chat & generation**

- **FR-012**: After the model is installed, the user MUST be able to type and send a text
  message in a chat screen. Only one reply may be generated at a time: while a reply is
  generating, the send action MUST be unavailable and the stop control (FR-014) MUST be shown in
  its place, so the user stops or waits before sending the next message.
- **FR-013**: The assistant's reply MUST appear incrementally as it is generated — rendered in
  multiple visible updates as text is produced, never only as a single complete block once
  generation has finished.
- **FR-014**: While a reply is generating, a stop control MUST be visible; activating it MUST
  halt further generated text within 1 second and retain 100% of the text produced up to that
  moment as the assistant's turn.
- **FR-015**: The interface MUST remain responsive during generation: scroll and input gestures
  receive a visible response within 100 ms while a reply is streaming, and generation never
  blocks the interface.
- **FR-016**: The chat input MUST expose only text entry in this slice. Even though the active
  model may support other modalities, those affordances are out of scope and MUST be gated off
  through capability/scope configuration (data-driven), not hardcoded per-model conditionals,
  consistent with capability-driven UX.

**Conversational memory**

- **FR-017**: When generating a reply, the system MUST include the prior turns of the current
  conversation — including any stopped-partial assistant turn — in the context provided to the
  model. When the conversation exceeds the model's context window, the system MUST include the
  most recent turns that fit (a sliding window), dropping only the oldest turns from the
  context; the full conversation MUST remain stored and displayed. This is verifiable by
  inspecting the assembled context, independent of model quality.

**Persistence & history**

- **FR-018**: Conversations (their messages and order) MUST persist across app restarts.
- **FR-019**: The user MUST be able to start a new conversation.
- **FR-020**: The user MUST be able to view a list of past conversations and reopen any of them
  to see and continue its full message history.
- **FR-021**: Each conversation in the list MUST show a label derived from its first user
  message (truncated to ~40 characters) plus a timestamp; conversations with identical first
  messages are disambiguated by timestamp, and a conversation whose first message is empty after
  trimming MUST use a defined fallback label (e.g., "untitled" with its timestamp).
- **FR-022**: The user MUST be able to delete a conversation, after which its messages are no
  longer retrievable.

**Theme & presentation**

- **FR-023**: The app MUST default to a dark theme on first launch.
- **FR-024**: The user's theme preference MUST persist across app restarts.
- **FR-025**: Loading and active states MUST use the design system's pulsing dot motif rather
  than a generic spinner; the default palette MUST use the dark-theme tokens from the design
  system, with no gradients or drop shadows. Where a design-system token would fall below the
  accessibility floor for a given use (e.g., muted text for timestamps or labels), the
  accessibility floor (FR-031) prevails and a compliant value MUST be used.

**Privacy, offline & resource discipline**

- **FR-026**: The only network operation the system performs MUST be the one-time model
  download; no user content (messages, replies, or conversation metadata) may be transmitted
  off the device.
- **FR-027**: Once the model is installed, all core features (starting and continuing chats,
  viewing history) MUST work with no network connection.
- **FR-028**: Loss of connectivity during an active chat MUST NOT interrupt generation or cause
  loss of messages.
- **FR-029**: Exactly one model MUST be active at a time. Model/inference resources MUST be
  released when the user navigates away from the chat screen and when the app enters the
  background, without losing persisted conversation data.
- **FR-030**: The system MUST show that the model is installed and display its on-disk size in
  human-readable units, and MUST let the user delete the downloaded model to reclaim that space,
  returning to the onboarding/download state.

**Accessibility**

- **FR-031**: Accessibility is a release gate, not a follow-up. Every interactive control
  (download, cancel, send, stop, new-conversation, conversation row, delete) MUST have a touch
  target of at least 48dp and MUST meet WCAG AA contrast against its background.

**Data protection**

- **FR-032**: All locally stored conversation data MUST reside in app-private (sandboxed)
  storage and MUST be protected at rest by the platform's device encryption. No app-level
  database encryption is required in this slice, and no conversation data may be written outside
  the app's private storage.

### Key Entities *(include if feature involves data)*

- **Conversation**: An ordered collection of messages representing one chat thread. Has an
  identifier, a display label derived from its first message, and created/last-updated
  timestamps for ordering in the history list.
- **Message**: A single turn within a conversation. Has a role (user or assistant), text
  content, position/order within the conversation, a timestamp, and a completion state
  (complete vs. stopped-partial).
- **Installed Model**: The single default on-device model. Has an installed/not-installed
  status and a storage footprint; it is the one and only active model in this slice.
- **Device Capability (preflight result)**: A snapshot of available memory and processor
  architecture, plus whether the device meets the supported baseline; consumed before download.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In moderated usability testing with at least 8 first-time participants on
  supported devices with working connectivity, at least 90% reach the chat screen with an
  installed model using only on-screen guidance (the operator gives no hints).
- **SC-002**: While bytes are being received, both the percent and downloaded-of-total values
  refresh at least once per second; during a stall the UI indicates the stalled state at least
  once per second rather than appearing frozen.
- **SC-003**: Cancelling an in-progress download stops it within 2 seconds and leaves no
  partial or unusable model behind.
- **SC-004**: On the reference baseline device (a current-generation 8 GB arm64-v8a phone; the
  exact device is fixed in the test plan), the first words of the reply become visible within
  5 seconds (median of 5 runs) of the send action, and text continues to appear incrementally
  until the reply completes.
- **SC-005**: Within 1 second of the stop activation event, no further text is appended, and all
  text already rendered at that instant is retained verbatim as the assistant's turn.
- **SC-006**: After the app process terminates by any means (user force-quit, OS background
  kill, or crash) and is relaunched, 100% of conversations and their messages are present and in
  the same order.
- **SC-007**: With connectivity disabled after install, a user can create a conversation, send
  and receive at least 5 turns, reopen a past conversation, and browse history with zero
  failures attributable to network access (each send produces an assistant turn with no network
  call).
- **SC-008**: On a device below the supported baseline, the app explains the limitation before
  any download and produces zero crashes or out-of-memory terminations in this path.
- **SC-009**: Over the app's entire lifetime, the only network activity is the one-time model
  download; no request carries conversation content (verifiable via network monitoring and
  airplane-mode testing).
- **SC-010**: On first launch, 100% of first-time users see a dark theme by default.
- **SC-011**: While a reply streams, scroll and input gestures receive a visible response within
  100 ms.
- **SC-012**: Before release, every interactive element passes a 48dp minimum touch-target check
  and a WCAG AA contrast check.

## Assumptions

- The default model is the project's primary on-device model (Gemma 4 E2B, per the
  constitution and design system). Only this single default model is offered in this slice; the
  optional higher-quality model tier is out of scope here.
- The supported baseline is a 64-bit ARM (arm64-v8a) processor with at least 8 GB of RAM, per
  constitution Principle V. Devices below this are treated as unsupported. A device exactly at
  8 GB is supported and uses the default model.
- The model download is a large (multi-gigabyte), one-time download that runs under the
  platform's long-running-download rules so it can continue while the app is in use.
  "Survives the app continuing to run" means the download is non-blocking within the app
  session; chat remains gated until installation completes. If the app process is killed
  mid-download, the download resumes or restarts cleanly on next launch, and a partial file is
  never treated as a usable model. The model is fetched from an open, redistributable URL with
  no account or sign-in, preceded by a one-time in-app license acknowledgment.
- Stopping a reply retains the partial text as a completed (terminated) assistant turn that is
  included in the conversation's remembered context for later turns.
- Conversation list labels are derived from the first user message (truncated as needed) plus a
  timestamp; conversation rename and search are out of scope.
- The theme defaults to dark and the user's theme choice persists; a broader settings surface
  beyond theme is out of scope for this slice.
- Each send produces a single assistant response; regenerating or editing prior messages is out
  of scope.
- The visual language follows `.specify/memory/design-system.md` and constitution Principle X
  (monochrome, single red accent reserved for active/recording/stop/error states, dot-matrix
  motifs, no gradients/shadows).
- There are no user accounts, no cloud sync, and no analytics that capture conversation
  content, consistent with the constitution.
- At-rest protection of local conversation data relies on Android's file-based encryption and
  app-private storage; app-level database encryption is deferred as future hardening.

## Dependencies

- Relies on an on-device model runtime capable of loading the default model and producing
  output token-by-token; there is no backend service involved beyond the one-time model
  download source.
- Relies on local on-device storage for persisting conversations and the downloaded model.

## Out of Scope

The following are explicitly **not** part of this slice (planned for later features):

- Image input, audio input, function calling, and thinking-mode display.
- Backend/accelerator selection UI.
- Any multi-model management beyond the single default model (catalog, switching, the optional
  upgrade tier).
- Regenerating or editing messages; conversation rename, search, or export.
- Cloud sync, user accounts, and any networked features beyond the one-time model download.
