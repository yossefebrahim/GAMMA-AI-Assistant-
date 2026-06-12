import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/services/clipboard_tool_service.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_clipboard_tool_service.dart';

/// 004 US5 — the summarize_clipboard handler returns the bounded clipboard text (the SUMMARY
/// happens in the resumed generation), and maps an empty/non-text clipboard to a structured
/// failure (FR-025). Through the real dispatcher with a fake clipboard.
void main() {
  late FakeClipboardToolService clipboard;

  ProviderContainer build() {
    clipboard = FakeClipboardToolService();
    return makeContainer(
      overrides: [clipboardToolServiceProvider.overrideWithValue(clipboard)],
    );
  }

  test(
    'copied text → success result carrying the (untruncated) text',
    () async {
      final c = build();
      addTearDown(c.dispose);
      clipboard.text = 'the quick brown fox';

      final outcome = await c
          .read(toolDispatcherProvider)
          .dispatch('summarize_clipboard', const {});
      expect(outcome, isA<ToolSuccess>());
      final success = outcome as ToolSuccess;
      expect(success.result['text'], 'the quick brown fox');
      expect(success.result['truncated'], false);
    },
  );

  test(
    'empty clipboard → ToolFailure("clipboard empty or not text")',
    () async {
      final c = build();
      addTearDown(c.dispose);
      clipboard.text = null;

      final outcome = await c
          .read(toolDispatcherProvider)
          .dispatch('summarize_clipboard', const {});
      expect(outcome, isA<ToolFailure>());
      expect((outcome as ToolFailure).reason, 'clipboard empty or not text');
    },
  );

  test('over-4,000-char text is truncated with truncated: true', () async {
    final c = build();
    addTearDown(c.dispose);
    clipboard.text = 'x' * 5000;

    final outcome = await c
        .read(toolDispatcherProvider)
        .dispatch('summarize_clipboard', const {});
    final success = outcome as ToolSuccess;
    expect(
      (success.result['text'] as String).length,
      ClipboardToolService.maxClipboardChars,
    );
    expect(success.result['truncated'], true);
  });

  test('text exactly at the 4,000 bound is not marked truncated', () async {
    final c = build();
    addTearDown(c.dispose);
    clipboard.text = 'y' * ClipboardToolService.maxClipboardChars;

    final outcome = await c
        .read(toolDispatcherProvider)
        .dispatch('summarize_clipboard', const {});
    expect((outcome as ToolSuccess).result['truncated'], false);
  });
}
