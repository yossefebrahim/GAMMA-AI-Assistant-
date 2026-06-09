# Contract — GemmaService audio extensions (003)

Extends the as-built 001/002 contract; everything not listed here is unchanged.

## Interface deltas (`lib/domain/services/gemma_service.dart` — pure Dart, no plugin symbols)

```dart
Stream<String> generate({
  required List<ChatTurn> history,
  required String prompt,
  ImageInput? image,
  AudioInput? audio,   // NEW — the CURRENT prompt's clip (at most one of image/audio non-null)
});

class AudioProcessingException implements Exception {  // NEW — sibling of ImageProcessingException
  final String message; final Object? cause;
}
```

`loadModel(String filePath, {ModelCapabilities capabilities})` is unchanged in shape; passing
`ModelCapabilities(audio: true)` now enables the audio modality natively.

## Guarantees (numbered continues the 001/002 contract)

13. **Audio gate (caller-side contract)**: `generate(audio: …)` while `capabilities.audio == false`
    throws `StateError` synchronously. This is load-bearing, not ceremony: the plugin's FFI path
    **silently drops** ungated audio (research R1), so without this check a mis-configured load
    produces replies that ignore the clip with no error anywhere. `FakeGemmaService` models this
    StateError (closes 002 audit L6).
14. **Both-media rejection**: `generate` with `image != null && audio != null` throws `StateError`
    (spec Q3); `ChatTurn` carries at most one medium per turn.
15. **Typed audio failure, narrowly scoped**: plugin/native errors are remapped to
    `AudioProcessingException` **only when the current prompt carries audio** (`audio != null`).
    Errors on turns that merely have audio in replayed history propagate unchanged (002 audit L4
    applied at design time). The plugin's own exception types never cross the seam (hide on
    import if any collide).
16. **Audio context replay**: audio-bearing `ChatTurn`s in `history` are replayed to the native
    session (`Message.withAudio`/`audioOnly`) on resync, so follow-ups keep referring to the clip
    (FR-016/FR-017). The kept-warm fingerprint includes `audioByteLength`, so a warm session is
    never wrongly matched across differing audio.
17. **Capability flow unchanged**: capabilities are DATA from `loadModel`; `supportAudio: true` is
    threaded to **both** GPU and CPU activation attempts and to `createChat`;
    `_lastActivationError` still carries the real backend failure into `ModelLoadException` so an
    audio-enabled load failure is diagnosable — never a silent flip to a lesser capability set.

## Concrete mapping (`lib/infrastructure/gemma/flutter_gemma_service.dart` — the only flutter_gemma importer)

| Seam | flutter_gemma 0.15.3 |
|---|---|
| `loadModel(capabilities: audio)` | `getActiveModel(maxTokens: 2048, preferredBackend: gpu→cpu, supportImage: caps.image, maxNumImages: caps.image ? 1 : null, supportAudio: caps.audio)` then `createChat(modelType: gemma4, supportImage: caps.image, supportAudio: caps.audio, …)` |
| current prompt with audio | `Message.withAudio(text:, audioBytes:, isUser: true)` / `Message.audioOnly(audioBytes:)` (empty text) |
| history turn with audio | same mapping inside `clearHistory(replayHistory: …)` |
| failure mapping | catch around generate → `AudioProcessingException('could not process the audio', cause: e)` iff current-prompt audio |

## FakeGemmaService extensions (test double)

- records `lastAudio` (bytes length + mimeType) and `lastHistoryAudio` per call (FR-017 assertions);
- configurable capabilities (audio on/off) — default mirrors catalog (image+audio true);
- scriptable: throw `AudioProcessingException` on demand; `trailingDeltaAfterStop` retained (M1);
- **throws the guarantee-13 StateError and the guarantee-14 both-media StateError** for real.
