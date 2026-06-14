import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/fetch_result.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/web_search_result.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T062 (006 US7; FR-021; SC-001/SC-002/SC-003/SC-004/SC-013) — the OFFLINE / web-off guarantee
/// proven at the DISPATCH layer. Companion to `test/unit/web_gating_regression_test.dart` (T051),
/// which proves the same guarantee at DECLARATION time through the real [modelSessionProvider]; this
/// file complements it by additionally driving the REAL dispatcher ([toolDispatcherProvider]) to show
/// that validation ALWAYS precedes the network seam — a malformed/non-http(s) url or empty query never
/// reaches [NetworkResearchService].
///
/// HONEST scope note (architecture fact): the handler map in `tool_handler_providers.dart` is STATIC —
/// it always carries the `web_search`/`fetch_page` handlers, and those handlers guard only the BYOK
/// key, NOT the web toggle. Toggle gating happens at DECLARATION time (which tools are loaded into the
/// session), so this file does NOT assert "the dispatcher refuses a web call when the toggle is off"
/// (that would be false). Instead it asserts (1) web-off ⇒ web tools structurally absent + zero
/// network on session materialisation, (2) validation precedes the network seam, and (3) a positive
/// control so (1)/(2) are not vacuous.
void main() {
  late FakeNetworkResearchService network;

  setUp(() {
    network = FakeNetworkResearchService();
  });

  // ── 1. web off → structurally absent + offline on session materialisation ──────────────────────

  group(
    'web off → offline guarantee (companion to web_gating_regression_test.dart)',
    () {
      test(
        'web tools structurally absent AND materialising the session touches no network (FR-021)',
        () async {
          // Reuse the gating test's session-materialisation pattern: function-calling capable model,
          // a valid key seeded, but the GLOBAL web flag OFF (conversation override inherits — no active
          // id). The triple gate (functionCalling && effectiveWebEnabled && hasValidKey) resolves false
          // on the effectiveWebEnabled leg, so the web tools must never be declared.
          final gemma = FakeGemmaService(
            capabilitiesData: const ModelCapabilities(functionCalling: true),
          );
          final keyStore = FakeSecureKeyStore()..seed('tavily-key');
          final container = makeContainer(
            secureKeyStore: keyStore,
            networkResearch: network,
            overrides: [
              gemmaServiceProvider.overrideWithValue(gemma),
              installedModelPathProvider.overrideWith(
                (ref) async => '/fake/model',
              ),
              catalogCapabilitiesProvider.overrideWithValue(
                const ModelCapabilities(functionCalling: true),
              ),
              webAccessEnabledProvider.overrideWith(_WebOff.new),
            ],
          );
          addTearDown(container.dispose);

          final sub = container.listen(modelSessionProvider, (_, _) {});
          await container.read(modelSessionProvider.future);
          sub.close();

          // Structural absence: neither web tool is declared into the loaded session.
          final names = (gemma.loadedTools ?? const [])
              .map((t) => t.name)
              .toList();
          expect(names, isNot(contains('web_search')));
          expect(names, isNot(contains('fetch_page')));
          // Offline guarantee: simply standing up the session never reaches the network seam.
          expect(network.searchCallLog, isEmpty);
          expect(network.fetchCallLog, isEmpty);
        },
      );
    },
  );

  // ── 2. validation precedes the network seam (real dispatcher) ──────────────────────────────────

  group('validation precedes the network seam (real dispatcher, web ON + key)', () {
    /// A dispatcher wired with the REAL handler map over a container whose 006 seams are the
    /// configured fakes. The key is seeded so the handler's StateError key-guard never trips — the
    /// point here is that VALIDATION rejects the call before any handler / network code runs.
    ToolDispatcher dispatcher() {
      final keyStore = FakeSecureKeyStore()..seed('tvly-test-key');
      final container = makeContainer(
        secureKeyStore: keyStore,
        networkResearch: network,
      );
      addTearDown(container.dispose);
      return container.read(toolDispatcherProvider);
    }

    test('malformed url → ToolInvalidArgs, fetchPage never called', () async {
      final outcome = await dispatcher().dispatch('fetch_page', {
        'url': 'not-a-url',
      });
      expect(outcome, isA<ToolInvalidArgs>());
      // Schema rejection (format: uri) fires before the handler — the network seam is untouched.
      expect(network.fetchCallLog, isEmpty);
    });

    test(
      'non-http(s) scheme → ToolInvalidArgs, fetchPage never called',
      () async {
        final outcome = await dispatcher().dispatch('fetch_page', {
          'url': 'ftp://example.com',
        });
        expect(outcome, isA<ToolInvalidArgs>());
        // The scheme-allowlist step rejects ftp:// before the handler / network seam.
        expect(network.fetchCallLog, isEmpty);
      },
    );

    test('empty query → ToolInvalidArgs, search never called', () async {
      final outcome = await dispatcher().dispatch('web_search', {'query': ''});
      expect(outcome, isA<ToolInvalidArgs>());
      // Schema rejection (minLength) fires before the handler — the network seam is untouched.
      expect(network.searchCallLog, isEmpty);
    });
  });

  // ── 3. positive control (so 1 & 2 are not vacuous) ─────────────────────────────────────────────

  group(
    'positive control: web ON + key + stub → the network seam IS reached',
    () {
      ToolDispatcher dispatcher() {
        final keyStore = FakeSecureKeyStore()..seed('tvly-test-key');
        final container = makeContainer(
          secureKeyStore: keyStore,
          networkResearch: network,
        );
        addTearDown(container.dispose);
        return container.read(toolDispatcherProvider);
      }

      test(
        'valid web_search → ToolSuccess + the query reaches search()',
        () async {
          network.stubSearch('dart 3 records', const [
            WebSearchResult(
              title: 't',
              url: 'https://dart.dev/a',
              content: 'c',
              score: 0.9,
            ),
          ]);

          final outcome = await dispatcher().dispatch('web_search', {
            'query': 'dart 3 records',
          });

          expect(outcome, isA<ToolSuccess>());
          // The valid call DID reach the network seam — proving the empty-call-log assertions above are
          // load-bearing, not vacuously true.
          expect(network.searchCallLog, contains('dart 3 records'));
        },
      );

      test(
        'valid fetch_page → ToolSuccess + the url reaches fetchPage()',
        () async {
          network.stubFetch(
            'https://flutter.dev/docs',
            const FetchResult(
              url: 'https://flutter.dev/docs',
              extractedText: 'the readable extracted text of the page',
              wasTruncated: false,
            ),
          );

          final outcome = await dispatcher().dispatch('fetch_page', {
            'url': 'https://flutter.dev/docs',
          });

          expect(outcome, isA<ToolSuccess>());
          expect(network.fetchCallLog, contains('https://flutter.dev/docs'));
        },
      );
    },
  );

  // Guard: these assertions only mean something while the catalog model is tool-capable (the gate's
  // functionCalling leg). If the pinned model ever flips text-only, this surfaces the assumption.
  test('precondition: catalog model is function-calling capable', () {
    expect(ModelCatalog.capabilities.functionCalling, isTrue);
  });
}

/// [webAccessEnabledProvider] stub: global web access OFF (mirrors the gating test's `_WebOff`).
class _WebOff extends WebAccessEnabledController {
  @override
  bool build() => false;
}
