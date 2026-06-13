import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T051 (006 US7; FR-006, FR-021; SC-009, SC-010, SC-011) — structural gating regression, driven
/// through the REAL [modelSessionProvider]. The web tools (`web_search`, `fetch_page`) are declared
/// IF AND ONLY IF the triple gate is true (`functionCalling && effectiveWebEnabled && hasValidKey`).
/// Under every off condition the declared tool list MUST NOT contain the web tools and the network
/// seam MUST NEVER be touched (zero `searchCallLog` / `fetchCallLog` entries) — byte-for-byte
/// identical to pre-006.
///
/// Widget-level history rendering under any capability state (scenario d) lives in
/// `test/widget/tool_gating_regression_test.dart` (the persisted-chip-outlives-capability rule) and
/// `test/widget/web_history_chip_test.dart` (web chips render regardless of current toggle state).
void main() {
  late FakeGemmaService gemma;
  late FakeNetworkResearchService network;

  setUp(() {
    network = FakeNetworkResearchService();
  });

  /// Build a container with the given gate inputs and materialise the session, returning the
  /// FakeGemmaService so the caller can inspect `loadedTools`.
  Future<FakeGemmaService> loadSession({
    required ModelCapabilities capabilities,
    required bool globalWebEnabled,
    required String? key,
  }) async {
    gemma = FakeGemmaService(capabilitiesData: capabilities);
    final keyStore = FakeSecureKeyStore();
    if (key != null) keyStore.seed(key);
    final container = makeContainer(
      secureKeyStore: keyStore,
      networkResearch: network,
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
        catalogCapabilitiesProvider.overrideWithValue(capabilities),
        webAccessEnabledProvider.overrideWith(
          () => globalWebEnabled ? _WebOn() : _WebOff(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(modelSessionProvider, (_, _) {});
    await container.read(modelSessionProvider.future);
    sub.close();
    return gemma;
  }

  void expectNoWebToolsDeclared(FakeGemmaService g) {
    final names = (g.loadedTools ?? const []).map((t) => t.name).toList();
    expect(names, isNot(contains('web_search')));
    expect(names, isNot(contains('fetch_page')));
  }

  void expectNoNetworkCalls() {
    expect(network.searchCallLog, isEmpty);
    expect(network.fetchCallLog, isEmpty);
  }

  test(
    '(a) functionCalling=false → zero web tools declared, zero tools at all, zero network (SC-009)',
    () async {
      final g = await loadSession(
        capabilities: ModelCapabilities.textOnly,
        globalWebEnabled: true, // even with the global flag on...
        key: 'tavily-key', // ...and a valid key...
      );
      // ...a text-only model declares NO tools at all — byte-parity with pre-004/006.
      expect(g.loadedTools, isEmpty);
      expectNoWebToolsDeclared(g);
      expectNoNetworkCalls();
    },
  );

  test(
    '(b) no key stored → web tools absent regardless of toggles (SC-011)',
    () async {
      // Guard: this matters only while the catalog model is tool-capable.
      expect(ModelCatalog.capabilities.functionCalling, isTrue);
      final g = await loadSession(
        capabilities: const ModelCapabilities(functionCalling: true),
        globalWebEnabled: true, // global on, but...
        key: null, // ...no key → triple gate fails.
      );
      expectNoWebToolsDeclared(g);
      // Device tools still declared (function calling on) — only the WEB tools are absent.
      expect(
        (g.loadedTools ?? const []).map((t) => t.name),
        contains('get_device_info'),
      );
      expectNoNetworkCalls();
    },
  );

  test(
    '(c) both toggles off (global off, inherit) → zero web tools, zero network (SC-010)',
    () async {
      final g = await loadSession(
        capabilities: const ModelCapabilities(functionCalling: true),
        globalWebEnabled:
            false, // global off; conversation override inherits (no active id)
        key: 'tavily-key',
      );
      expectNoWebToolsDeclared(g);
      expectNoNetworkCalls();
    },
  );

  test(
    '(e) web off (no key) → behavior identical to pre-006, zero network (FR-021)',
    () async {
      // The catch-all FR-021 case: any combination that resolves to web-off declares no web tools.
      final g = await loadSession(
        capabilities: const ModelCapabilities(functionCalling: true),
        globalWebEnabled: false,
        key: null,
      );
      expectNoWebToolsDeclared(g);
      expectNoNetworkCalls();
    },
  );

  test('positive control: triple gate true → web tools ARE declared', () async {
    expect(ModelCatalog.capabilities.functionCalling, isTrue);
    final g = await loadSession(
      capabilities: const ModelCapabilities(functionCalling: true),
      globalWebEnabled: true,
      key: 'tavily-key',
    );
    final names = (g.loadedTools ?? const []).map((t) => t.name).toList();
    expect(names, containsAll(<String>['web_search', 'fetch_page']));
    // Even when declared, simply LOADING the session never touches the network.
    expectNoNetworkCalls();
    // And the full registry is present (eight tools).
    expect(g.loadedTools, hasLength(ToolRegistry.specs.length));
  });
}

/// [webAccessEnabledProvider] stub: global web access ON.
class _WebOn extends WebAccessEnabledController {
  @override
  bool build() => true;
}

/// [webAccessEnabledProvider] stub: global web access OFF.
class _WebOff extends WebAccessEnabledController {
  @override
  bool build() => false;
}
