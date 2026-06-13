import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:ai_assistant/domain/entities/web_access_override.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T029 (006 US1, FR-006/FR-007, SC-009/SC-010/SC-011) — the effective-web-toggle resolver + the
/// triple gate.
///
/// Part A: [WebAccessOverride.effectiveWebEnabled] over all 6 global × per-conversation combinations.
/// Part B: the session provider's tool declaration — `webTools` present IFF all three gate
/// conditions (functionCalling && effectiveWebEnabled && hasValidKey) hold; structurally absent
/// otherwise (the tools are not declared, not refused at runtime).

/// Stub notifier driving [webAccessEnabledProvider] to a fixed value without touching the DB.
class _FixedWebAccess extends WebAccessEnabledController {
  _FixedWebAccess(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // Part A — the resolver: 6 global × per-conversation combinations (FR-007)
  // ─────────────────────────────────────────────────────────────────────────
  group(
    'EffectiveWebToggle resolver (WebAccessOverride.effectiveWebEnabled)',
    () {
      test('inherit + global-on = true', () {
        expect(WebAccessOverride.inherit.effectiveWebEnabled(true), isTrue);
      });
      test('inherit + global-off = false', () {
        expect(WebAccessOverride.inherit.effectiveWebEnabled(false), isFalse);
      });
      test('explicitly-on + global-off = true', () {
        expect(WebAccessOverride.on.effectiveWebEnabled(false), isTrue);
      });
      test('explicitly-on + global-on = true', () {
        expect(WebAccessOverride.on.effectiveWebEnabled(true), isTrue);
      });
      test('explicitly-off + global-on = false', () {
        expect(WebAccessOverride.off.effectiveWebEnabled(true), isFalse);
      });
      test('explicitly-off + global-off = false', () {
        expect(WebAccessOverride.off.effectiveWebEnabled(false), isFalse);
      });

      test('null (DB inherit) coerces to inherit semantics', () {
        const override = WebAccessOverride.inherit;
        // A null override read from the DB is treated as inherit (data-model §1).
        const WebAccessOverride? fromDb = null;
        expect((fromDb ?? override).effectiveWebEnabled(true), isTrue);
        expect((fromDb ?? override).effectiveWebEnabled(false), isFalse);
      });
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Part B — the triple gate at the session-provider level
  // ─────────────────────────────────────────────────────────────────────────
  group(
    'triple gate — webTools present iff functionCalling && effectiveWebEnabled && hasValidKey',
    () {
      /// Loads [modelSessionProvider] with the given gate inputs and returns the tools the fake
      /// GemmaService received. functionCalling is driven via [catalogCapabilitiesProvider].
      Future<List<ToolSpec>> loadedToolsFor({
        required bool functionCalling,
        required bool webAccessEnabled,
        required bool hasKey,
      }) async {
        final keyStore = FakeSecureKeyStore();
        if (hasKey) keyStore.seed('tvly-key');
        final gemma = FakeGemmaService(
          capabilitiesData: ModelCapabilities(functionCalling: functionCalling),
        );
        final container = makeContainer(
          secureKeyStore: keyStore,
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            installedModelPathProvider.overrideWith(
              (ref) async => '/fake/model',
            ),
            catalogCapabilitiesProvider.overrideWithValue(
              ModelCapabilities(functionCalling: functionCalling),
            ),
            webAccessEnabledProvider.overrideWith(
              () => _FixedWebAccess(webAccessEnabled),
            ),
          ],
        );
        addTearDown(container.dispose);
        final sub = container.listen(modelSessionProvider, (_, _) {});
        addTearDown(sub.close);
        await container.read(modelSessionProvider.future);
        return gemma.loadedTools ?? const [];
      }

      bool hasWebTools(List<ToolSpec> tools) =>
          tools.any((t) => ToolRegistry.webTools.contains(t));

      test('all three true → webTools present', () async {
        final tools = await loadedToolsFor(
          functionCalling: true,
          webAccessEnabled: true,
          hasKey: true,
        );
        expect(hasWebTools(tools), isTrue);
      });

      test(
        'functionCalling=false → webTools absent (also zero device/memory tools)',
        () async {
          final tools = await loadedToolsFor(
            functionCalling: false,
            webAccessEnabled: true,
            hasKey: true,
          );
          expect(hasWebTools(tools), isFalse);
          // function calling off → the whole tool list is empty (byte-parity, SC-009).
          expect(tools, isEmpty);
        },
      );

      test('no key → webTools absent regardless of toggles (SC-011)', () async {
        final tools = await loadedToolsFor(
          functionCalling: true,
          webAccessEnabled: true,
          hasKey: false,
        );
        expect(hasWebTools(tools), isFalse);
      });

      test(
        'effectiveWebEnabled=false (global off, inherit) → webTools absent (SC-010)',
        () async {
          final tools = await loadedToolsFor(
            functionCalling: true,
            webAccessEnabled: false,
            hasKey: true,
          );
          expect(hasWebTools(tools), isFalse);
        },
      );
    },
  );
}
