# Feature Specification: Image Input — Visual Understanding

**Feature Branch**: `002-image-input-vision`

**Created**: 2026-06-08

**Status**: Draft

**Input**: User description: "Add image input (visual understanding) to the On-Device Gemma Assistant — its first multimodal capability. From the chat screen, a user can attach a single image to a message, either by taking a new photo with the camera or choosing an existing one from their photo library. Before sending, the chosen image appears as a preview in the message composer so the user can confirm it or remove it and pick another. The user may send the image on its own or together with a text prompt (for example, attaching a photo and asking \"what's in this picture?\"). When the user has not granted camera or photo-library access, the app explains why it needs access and guides them to enable it, rather than failing silently. After sending, the image appears inside the user's message in the conversation, and the assistant replies about it — describing or analyzing what it sees — with the reply streaming in word-by-word as text replies already do. Within the same conversation, the user can continue asking follow-up questions and the assistant can keep referring to the image it was shown. Image attachment is only offered when the currently active model can understand images. If the active model is text-only, the attach-image control is not shown, and the user can still chat normally with text. If the user switches models, the control appears or disappears accordingly. Images already sent in a conversation remain visible in that conversation's history even if the user later switches to a text-only model. Conversations that contain images persist across app restarts, with the image still shown in place. If the device or active model cannot process a given image, the user receives a clear message instead of a hang or crash. Out of scope for this phase: audio input, multiple images in a single message, image generation or editing, attaching non-image files such as PDFs or documents, on-image drawing or annotation, function calling, and thinking-mode display."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Attach an image and get a reply about it (Priority: P1)

From the chat screen, with an image-capable model active, the user attaches a single image —
either by taking a new photo with the camera or by choosing an existing one from their photo
library. The chosen image appears as a preview in the message composer, where the user can
confirm it, remove it, or replace it with a different one. The user sends the image on its own,
or together with a text prompt such as "what's in this picture?". After sending, the image
appears inside the user's message in the conversation, and the assistant replies about what it
sees — describing or analyzing the image — with the reply streaming in word-by-word, exactly as
text-only replies already do.

**Why this priority**: This is the entire point of the feature — the assistant's first
multimodal capability. Everything else (memory about the image, capability gating, permissions,
persistence) supports or protects this core exchange. If only this story ships, the product
gains a complete, demonstrable visual-understanding capability.

**Independent Test**: With an image-capable model installed and access already granted, attach
an image from the library (and separately, capture one with the camera), confirm the preview
appears, optionally add a text prompt, send, and verify the image shows inside the user message
and the assistant's reply about the image streams in incrementally.

**Acceptance Scenarios**:

1. **Given** an image-capable model is active and access is granted, **When** the user opens the
   attach-image control and chooses "photo library", **Then** they can select one image and it
   appears as a preview in the composer before sending.
2. **Given** the attach-image control is open, **When** the user chooses "camera", **Then** they
   can capture a new photo and it appears as a preview in the composer before sending.
3. **Given** an image is previewed in the composer, **When** the user removes it, **Then** the
   preview clears and no image is attached to the next send; **When** instead the user picks
   another image, **Then** the preview is replaced by the new image (still a single image).
4. **Given** an image is previewed, **When** the user sends with no text, **Then** the message is
   sent with the image alone and the assistant replies about the image.
5. **Given** an image is previewed, **When** the user sends together with a text prompt, **Then**
   the message carries both the image and the text and the assistant's reply addresses the prompt
   in the context of the image.
6. **Given** a message with an image has been sent, **When** the conversation renders, **Then**
   the image appears inside the user's message and the assistant's reply streams in word-by-word
   rather than appearing only as a single finished block.

---

### User Story 2 - Attach control reflects the active model's capabilities (Priority: P2)

The attach-image control is offered only when the currently active model can understand images.
If the active model is text-only, the control is not shown and the user can still chat normally
with text. When the user switches models, the control appears or disappears to match the newly
active model. Images already sent in a conversation remain visible in that conversation's
history even if the user later switches to a text-only model.

**Why this priority**: Honest, capability-driven affordances are a core product principle — the
UI must never offer an input the active model cannot handle. This protects the P1 experience
from breaking when models are swapped, but the P1 capability is demonstrable on a single
image-capable model without it, so it sits just below P1.

**Independent Test**: With an image-capable model active, confirm the attach-image control is
present; switch to a text-only model and confirm the control disappears while text chat still
works; switch back and confirm it reappears. In a conversation that already contains a sent
image, switch to a text-only model and confirm the previously sent image is still shown in
history.

**Acceptance Scenarios**:

1. **Given** an image-capable model is active, **When** the user views the message composer,
   **Then** the attach-image control is shown.
2. **Given** a text-only model is active, **When** the user views the message composer, **Then**
   the attach-image control is not shown and the user can still send text messages normally.
3. **Given** the user switches from a text-only model to an image-capable one (or vice versa),
   **When** the switch completes, **Then** the attach-image control appears or disappears to
   match the now-active model without requiring an app restart.
4. **Given** a conversation that already contains a sent image, **When** the user switches to a
   text-only model and reopens that conversation, **Then** the previously sent image is still
   visible in place in the history.

---

### User Story 3 - Follow-up questions that keep referring to the image (Priority: P2)

After the assistant replies about an image, the user asks follow-up questions in the same
conversation — without re-attaching the image — and the assistant keeps referring to the image
it was already shown, answering the new questions in its context.

**Why this priority**: Multimodal conversational memory is what makes the image feel like a
shared part of the conversation rather than a one-shot lookup. It builds directly on Story 1 and
is essential to a credible experience, but the core capability is demonstrable with a single
turn, so it ranks below P1.

**Independent Test**: Send an image with one question, receive a reply, then send one or more
text-only follow-ups that depend on the image (e.g., "and what color is it?"); verify the
replies reflect the previously shown image without the user re-attaching it.

**Acceptance Scenarios**:

1. **Given** a conversation in which an image was already sent and answered, **When** the user
   sends a text-only follow-up that depends on the image, **Then** the assistant's reply takes
   the previously shown image into account.
2. **Given** a conversation containing an image, **When** the assembled context for a follow-up
   turn is inspected, **Then** the earlier image is included in that context (subject to the
   model's context limits), verifiable independently of reply quality.

---

### User Story 4 - Clear guidance when camera or photo access is not granted (Priority: P2)

When the user has not granted camera or photo-library access, the app explains why it needs the
access and guides them to enable it, rather than failing silently. If the user declines, text
chat continues to work normally.

**Why this priority**: Without access, the attach flow cannot complete, and a silent failure
would read as a broken feature. Honest, actionable guidance upholds the product's
graceful-degradation promise. It is a guard around Story 1 rather than the core capability, so
it ranks P2.

**Independent Test**: With access not yet granted, tap the attach-image control's camera and
library options and verify the app explains why access is needed and offers a path to enable it
(e.g., a route to system settings); deny access and confirm the app shows a clear message and
that text chat still works.

**Acceptance Scenarios**:

1. **Given** photo-library access has not been granted, **When** the user chooses "photo
   library", **Then** the app explains why access is needed and provides a way to grant it,
   rather than silently doing nothing.
2. **Given** camera access has not been granted, **When** the user chooses "camera", **Then** the
   app explains why access is needed and provides a way to grant it.
3. **Given** access was permanently denied, **When** the user retries, **Then** the app explains
   the situation and guides the user to the system settings where access can be changed.
4. **Given** the user declines to grant access, **When** they return to the chat, **Then** text
   messaging continues to work normally with no broken or stuck state.

---

### User Story 5 - Image conversations persist across restarts (Priority: P3)

The user closes and reopens the app and finds conversations that contain images intact, with
each image still shown in place within the message it was sent in.

**Why this priority**: Persistence turns a multimodal exchange into part of the durable history
users rely on. It is expected behavior, but the capability is demonstrable within a single
session, so it ranks below the interactive stories.

**Independent Test**: Send an image (with and without text), force-quit the app, relaunch, reopen
the conversation, and confirm the image is still displayed in place and the surrounding messages
and order are intact.

**Acceptance Scenarios**:

1. **Given** a conversation that contains one or more sent images, **When** the app is force-quit
   and relaunched, **Then** the conversation, its messages, their order, and each image are all
   present and shown in place.
2. **Given** a restored conversation with an image, **When** the user continues it with a
   follow-up, **Then** the conversation continues normally with the image still part of its
   history.

---

### User Story 6 - Honest handling when an image cannot be processed (Priority: P3)

If the device or the active model cannot process a given image, the user receives a clear
message explaining that the image could not be processed, instead of a hang, freeze, or crash.

**Why this priority**: Visual understanding is resource-intensive on constrained devices, and
some images may exceed what the device or model can handle. Failing honestly upholds the
graceful-degradation promise. It is a safety net around the happy path, so it ranks P3.

**Independent Test**: Induce an image the device/model cannot process (e.g., one that exceeds
processing limits on the baseline device) and confirm the app surfaces a clear, actionable
message and remains usable, with no crash, out-of-memory kill, or indefinite hang.

**Acceptance Scenarios**:

1. **Given** an image the active model cannot process, **When** the user sends it, **Then** the
   app shows a clear message that the image could not be processed and the conversation remains
   usable.
2. **Given** processing an image would exceed the device's resources, **When** the user sends it,
   **Then** the app fails gracefully with an explanation rather than crashing or hanging
   indefinitely.
3. **Given** an image-grounded reply is generating, **When** the user activates the stop control,
   **Then** generation halts promptly and any text produced so far is retained, exactly as for
   text-only replies.

---

### Edge Cases

- **Access granted to only a limited photo selection**: the user can still pick from the images
  they made available, and the app does not present the limited selection as an outright denial.
- **User cancels the picker or camera without choosing**: the composer returns to its prior
  state with no attachment added and no error.
- **Pending (previewed but unsent) image when the user switches to a text-only model**: the
  pending attachment is cleared and the user is told why, since the now-active model cannot
  accept it; text chat continues normally.
- **Unsupported or corrupt image file**: the app reports that the image cannot be used and lets
  the user pick another, rather than failing silently or crashing.
- **Very large or high-resolution image**: the app prepares the image for the model (e.g.,
  resizing as needed) so a large file does not by itself cause a failure; if it still cannot be
  processed, Story 6 applies.
- **Backgrounding the app mid image-grounded generation**: generation stops, any partial reply
  is retained, and model resources are released without losing the saved message or its image.
- **Connectivity lost while attaching or sending an image**: has no effect — attachment,
  sending, and image-grounded generation all work fully offline.
- **Deleting a conversation that contains images**: the conversation and its stored image data
  are removed together; no orphaned image remains.
- **Sending an empty message with no image and no text**: sending remains prevented until there
  is an image, text, or both.
- **Switching the active model mid-generation**: the in-flight generation is handled per existing
  rules (stopped and resources released) before the model switch takes effect.

## Requirements *(mandatory)*

### Functional Requirements

**Image attachment & composer**

- **FR-001**: When an image-capable model is active, the message composer MUST offer an
  attach-image control that lets the user attach a single image from one of two sources: taking a
  new photo with the camera, or choosing an existing photo from the device's photo library.
- **FR-002**: A message MUST carry at most one image. If the user picks another image while one
  is already previewed, the new image MUST replace the previous one (never add a second).
- **FR-003**: Before sending, the chosen image MUST appear as a preview in the composer, and the
  user MUST be able to remove it (clearing the attachment) or replace it with a different image.
- **FR-004**: The user MUST be able to send a message containing the image alone, or the image
  together with a text prompt. Sending MUST remain prevented only when there is neither an image
  nor any text.

**Capability-driven affordance**

- **FR-005**: The attach-image control MUST be shown only when the currently active model can
  understand images. When a text-only model is active, the control MUST NOT be shown or enabled,
  and the user MUST still be able to send text messages normally.
- **FR-006**: Whether to show the attach-image control MUST be determined from the active model's
  declared capabilities (queried as data), not from hardcoded per-model conditionals.
- **FR-007**: When the user switches the active model, the attach-image control MUST appear or
  disappear to match the now-active model's image capability without requiring an app restart.
- **FR-008**: A previewed-but-unsent image MUST be cleared if the user switches to a model that
  cannot understand images, and the user MUST be told why; text chat MUST continue normally.

**Access permissions**

- **FR-009**: When camera or photo-library access has not been granted, the system MUST explain
  why the access is needed and guide the user to grant it, rather than failing silently or doing
  nothing.
- **FR-010**: When access has been permanently denied, the system MUST explain the situation and
  guide the user to the system settings where access can be changed.
- **FR-011**: If the user declines access, the app MUST remain fully usable for text chat with no
  broken, stuck, or crashing state.

**Sending, display & streaming**

- **FR-012**: After sending, the image MUST appear inside the user's message in the conversation,
  rendered in place within that message.
- **FR-013**: The assistant MUST reply about the image — describing or analyzing what it sees —
  and the reply MUST stream in incrementally (word-by-word / progressive updates), consistent
  with how text-only replies stream.
- **FR-014**: While an image-grounded reply is generating, the stop control MUST be available and
  MUST behave exactly as for text replies: activating it halts further generation promptly and
  retains the text produced so far as the assistant's turn.

**Multimodal conversational memory**

- **FR-015**: Within the same conversation, the user MUST be able to ask text-only follow-up
  questions that refer to a previously sent image without re-attaching it, and the assistant MUST
  be able to keep referring to that image.
- **FR-016**: When generating a follow-up reply, the system MUST include the earlier image in the
  context provided to the model, subject to the model's context limits; this MUST be verifiable
  by inspecting the assembled context independent of reply quality.

**History & persistence**

- **FR-017**: Images already sent in a conversation MUST remain visible in that conversation's
  history even if the user later switches to a text-only model.
- **FR-018**: Conversations that contain images MUST persist across app restarts, with each image
  still shown in place within the message it was sent in.
- **FR-019**: Deleting a conversation MUST also remove the image data stored for it, leaving no
  orphaned image content.

**Graceful degradation & errors**

- **FR-020**: If the device or the active model cannot process a given image, the system MUST
  present a clear, actionable message that the image could not be processed, and MUST NOT hang,
  freeze, out-of-memory crash, or terminate without explanation.
- **FR-021**: The system MUST prepare a chosen image for the active model (e.g., resizing or
  re-encoding as required) so that a large or high-resolution file does not by itself cause a
  failure; an unsupported or corrupt image MUST be reported clearly with the option to pick
  another.

**Privacy, offline & resource discipline**

- **FR-022**: Image data MUST be processed entirely on-device. No image content (the image
  itself, derived data, or the resulting analysis) may be transmitted off the device; the only
  permitted network operation in the product remains the one-time model download.
- **FR-023**: Attaching, sending, and image-grounded generation MUST work with no network
  connection once an image-capable model is installed.
- **FR-024**: All stored image data MUST reside in app-private (sandboxed) storage protected at
  rest by the platform's device encryption, with no image written outside the app's private
  storage.
- **FR-025**: Image-grounded inference MUST NOT run on the UI thread; the interface MUST remain
  responsive while an image is being prepared and while a reply is generating, and model/session
  resources MUST be released on navigation away or backgrounding, consistent with existing
  resource rules.

**Accessibility & design**

- **FR-026**: Every new interactive control (attach-image, the camera and library options, the
  preview's remove/replace actions, and any access-prompt actions) MUST have a touch target of at
  least 48dp and meet WCAG AA contrast against its background.
- **FR-027**: The composer preview and the in-message image, along with any new loading/active
  states, MUST follow the design system (monochrome surfaces, hairline separation, no
  gradients/shadows, the red accent reserved for active/stop/error states, dot-matrix/Glyph-style
  motion for loading).

### Key Entities *(include if feature involves data)*

- **Image Attachment**: The single image associated with one user message. Has a stored reference
  to the on-device image data, its source (camera capture or library selection), and the
  prepared form used for the model. Bound to exactly one message; removed when that message's
  conversation is deleted.
- **Message (extended)**: A turn within a conversation that, for the user role, MAY now include
  one image attachment in addition to (or instead of) text. Existing message attributes (role,
  order, timestamp, completion state) are unchanged.
- **Model Image Capability**: The data describing whether the currently active model can
  understand images, queried to decide whether the attach-image affordance is shown. Part of the
  active model's broader capability set, not a hardcoded per-model flag.
- **Access Permission State**: Whether camera and photo-library access are granted, denied, or
  permanently denied — used to drive the explanatory guidance rather than silent failure.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In moderated usability testing with at least 8 participants on supported,
  image-capable devices, at least 90% successfully attach an image (via either camera or library)
  and receive an assistant reply about it using only on-screen guidance.
- **SC-002**: With an image-capable model active, the attach-image control is present in 100% of
  observed sessions; with a text-only model active, it is absent in 100% of observed sessions;
  and on model switch the control updates to match within the model-switch completion, with no
  app restart, in 100% of trials.
- **SC-003**: On the reference baseline device (a current-generation 8 GB arm64-v8a phone, fixed
  in the test plan), for a single typical photo the first words of the assistant's reply become
  visible within 20 seconds (median of 5 runs) of the send action, and text continues to appear
  incrementally until the reply completes.
- **SC-004**: A previously sent image is rendered in place inside its user message in 100% of
  conversations that contain images, including after switching to a text-only model.
- **SC-005**: After the app process terminates by any means and is relaunched, 100% of
  conversations containing images are restored with their images shown in place and message order
  intact.
- **SC-006**: In a conversation with a prior image, text-only follow-up turns include the earlier
  image in the assembled model context in 100% of trials (subject to context limits), verifiable
  by inspecting the assembled context.
- **SC-007**: When access is not granted, 100% of attach attempts produce an explanatory message
  with a path to enable access; zero attempts result in a silent no-op, and text chat remains
  fully usable in 100% of these cases.
- **SC-008**: In the unprocessable-image path (device or model cannot handle the image), 100% of
  attempts produce a clear message and zero produce a crash, out-of-memory kill, or indefinite
  hang.
- **SC-009**: With connectivity disabled after install, a user can attach and send an image and
  receive a reply, and ask at least 3 image-referencing follow-ups, with zero failures
  attributable to network access and zero network requests carrying image content (verifiable via
  network monitoring and airplane-mode testing).
- **SC-010**: While an image-grounded reply streams, scroll and input gestures receive a visible
  response within 100 ms.
- **SC-011**: Before release, every new interactive element passes a 48dp minimum touch-target
  check and a WCAG AA contrast check.

## Assumptions

- "Visual understanding" means the assistant interprets an image the user provides; it does NOT
  generate, edit, or modify images. This phase adds image **input** only.
- The active default model (Gemma 4 E2B, and the optional E4B tier) supports image input per the
  constitution; capability gating is nonetheless data-driven so the affordance behaves correctly
  for any future text-only model.
- Exactly one image per message is supported in this phase; multiple images in a single message
  are out of scope.
- A chosen image is copied into app-private storage and retained for the life of its conversation
  (shown in history, included in context for follow-ups), and deleted when its conversation is
  deleted. App-level database encryption is not added in this phase; at-rest protection relies on
  app-private storage plus platform device encryption, consistent with the existing slice.
- The app normalizes images (e.g., resizing/re-encoding) to a form the active model accepts;
  common photo formats produced by the device camera and library are supported. Unsupported or
  corrupt files are reported clearly with the option to pick another.
- Image-grounded first-token latency is higher than text-only latency because the image must be
  prepared and encoded before generation; the success-criteria target accounts for this on the
  baseline device.
- Capability gating, streaming, stop/cancel, conversational memory, persistence, and the design
  language all reuse the patterns established in the first slice (001-model-download-chat) and the
  constitution; this feature extends them to images rather than redefining them.
- The visual language follows `.specify/memory/design-system.md` and constitution Principle X
  (monochrome, single red accent reserved for active/recording/stop/error states, dot-matrix
  motifs, no gradients/shadows).
- There are no user accounts, no cloud sync, and no analytics that capture conversation content
  or image data, consistent with the constitution.

## Dependencies

- Relies on the on-device model runtime being able to accept an image alongside text and produce
  output token-by-token grounded in that image; there is no backend service involved.
- Relies on device camera and photo-library access (subject to the platform's permission model)
  for acquiring images.
- Relies on local on-device storage for persisting images alongside conversation data, and builds
  on the existing chat, capability, persistence, and resource-management foundations from
  001-model-download-chat.

## Out of Scope

The following are explicitly **not** part of this phase (planned for later features):

- Audio input.
- Multiple images in a single message.
- Image generation or editing (the assistant understands images but does not create or modify
  them).
- Attaching non-image files such as PDFs or documents.
- On-image drawing or annotation.
- Function calling.
- Thinking-mode display.
