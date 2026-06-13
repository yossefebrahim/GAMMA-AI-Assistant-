# Research — 006 Web Research (decisions & pinned choices)

All claims about provider behaviour are grounded in the Phase 0 spike
([spike-findings.md](spike-findings.md)) — live API probes, ToS audit, source inspection on
`flutter_gemma 0.15.3`, and context budget arithmetic confirmed on the A34. New packages are
introduced only where there is no existing substitute in the stack (Lean Scope); each is isolated
behind its own seam (Constitution v2.0.0 Principle VII).

---

## R1 — HTTP client: `package:http ^1.6.0` (lean, official, already transitive)

**Decision**: use `package:http` (dart-lang/http) at `^1.6.0`. Do NOT add `dio`.

**Rationale (Lean Scope)**: `package:http` is the official Dart HTTP library, already resolves
transitively through `background_downloader ^9.5.5` (which ships it), so adding it as a direct
dep costs zero binary-size overhead. The two operations this feature needs are a POST to
`https://api.tavily.com/search` and a GET to arbitrary target URLs — both one-shot, no streaming,
no interceptor pipeline, no multipart. Dio's additional features (global base URL, interceptor
chain, automatic JSON decoding, retry adapters) are all out of scope (Lean Scope, Constitution
IX).

**Timeout**: `package:http` 1.5.0+ supports abortable requests via `Abortable.abortTrigger`
(`Future<void>` completer). For per-request wall-clock timeout the caller wraps the request
`Future` in `Future.timeout(duration, onTimeout: () { abortTrigger.complete(); })` — two lines,
zero new dependency. The `IOClient` (used on Android via `dart:io`) honours `abortTrigger`
cancellation with a `RequestAbortedException`. This is adequate for the two narrow call patterns
(Tavily POST, target-site GET); a configurable `kTavilyTimeoutMs = 10000` and
`kFetchTimeoutMs = 15000` constant in `NetworkResearchService` covers both.

**Version confirmed**: pub.dev as of June 2026 — latest stable is **1.6.0** (published ~7 months
ago). Pin: `http: ^1.6.0`.

**Conflict check**: no conflict with `flutter_gemma ^0.15.0` (uses LiteRT-LM via FFI, no HTTP
dep), `drift ^2.33.0` (SQLite only), or `sqlite3 ^3.3.0`. The `dart:io`-based `IOClient` used on
Android has no JNI layer — cannot collide with native Gemma FFI.

---

## R2 — HTML parser: `package:html ^0.15.6` (pure Dart, already in spike scope)

**Decision**: use `package:html` at `^0.15.6`. Do NOT add a third-party readability package.
Implement extraction heuristics ourselves (the `HtmlExtractor` class in
`lib/infrastructure/network/html_extractor.dart`).

**Version confirmed**: pub.dev as of June 2026 — latest stable is **0.15.6**
(published ~13 months ago). Dart SDK constraint is `>=3.0.0 <4.0.0`; compatible with our
`sdk: ^3.10.7`. The spec already cites `^0.15.4` in its Assumptions section; `^0.15.6` is a
compatible bump and the latest. Pin: `html: ^0.15.6`.

**Why no readability package**: two candidates were evaluated:

- `reader_mode 0.2.2` — a Dart port of Mozilla Readability.js. 0 pub-repo likes, 498 total
  downloads, just 150 pub points. Dual-licensed MPL-2.0 + Apache 2.0 (MPL-2.0 requires
  file-level source disclosure on modifications — acceptable for pure Dart but a legal overhead
  to track). More critically, it depends on `package:html ^0.15.5` (same dep we already need)
  and layers JSDOMParser semantics on top — ~800 lines of Readability.js-mimicking logic that the
  spike confirmed we do not need (the extraction pipeline works with 5 rules and a priority-order
  DOM selector). The extra abstraction is complexity without payoff.
- `readability 0.2.2` — wraps a NATIVE readability library via FFI (`ffi ^2.1.2` +
  `plugin_platform_interface ^2.0.2`). Published 23 months ago with no recent updates. Adding a
  new native FFI dependency alongside `flutter_gemma` (which already occupies the LiteRT-LM
  native layer) is a risk multiplier — both share the Android `dlopen` namespace, and the
  0.15.3 spike showed caution is warranted here.

**Spike findings confirm bespoke heuristics suffice** (§2.1/§2.2): a priority-order DOM selector
(`article > main > [role="main"] > class/id heuristics > body`), boilerplate stripping (by tag
and class/id), link-density guard (>50% `<a>` text → discard), Wikipedia p-only rule (triggered
by URL containing `wikipedia.org`), and a `kMaxExtractedTokens = 4000` truncation ceiling
achieved **zero complete failures** across 10 real pages of varying types. The extraction
pipeline is tested against the 11 saved HTML fixtures in
`specs/006-web-research/fixtures/*.html` (news, docs, Wikipedia, blogs, gov) — which are the
same pages used in the spike — so coverage is empirically grounded before device runs.

**No other pure-Dart readability package exists** on pub.dev with production-ready maintenance:
a June 2026 search across pub.dev (`dart "pure readability" html extraction`) returned no
additional viable candidates beyond the two above. We implement ourselves.

---

## R3 — Secure key storage: `flutter_secure_storage ^10.3.1`

**Decision**: use `flutter_secure_storage` at `^10.3.1` (latest stable as of June 2026). Pin:
`flutter_secure_storage: ^10.3.1`. The package MUST sit behind its own
`SecureKeyStore` interface imported ONLY in `lib/infrastructure/network/` (Principle VII
discipline — same import-isolation pattern as `flutter_gemma` behind `GemmaService`).

**Version confirmed**: pub.dev — latest stable **10.3.1** (published ~16 days ago); a prerelease
`11.0.0-beta.1` exists but is not pinned (beta). Dart SDK `>=3.3.0` and Flutter `>=3.19.0` —
compatible with our Dart `^3.10.7` / Flutter 3.44.1 stack.

**Android mechanism (10.x)**: version 10.0.0 migrated away from the deprecated Jetpack
`EncryptedSharedPreferences` to a custom cipher implementation: RSA OAEP (SHA-256 +
MGF1Padding) for key wrapping + AES/GCM/NoPadding for data encryption. On Android >= API 23,
AES/GCM is available directly in the Android Keystore — the AES key is stored Keystore-backed.
Default configuration (no biometrics) stores a single wrapping RSA keypair in the Keystore and
encrypts data in `SharedPreferences` with an AES-GCM envelope. Data is still inaccessible
without the Keystore-held key, giving the same effective security guarantee as the former
`EncryptedSharedPreferences` (AES-256 Keystore-backed), satisfying FR-003 and spec Decision 1.

**minSdk constraint**: `flutter_secure_storage 10.x` requires `minSdkVersion = 23` (Android 6.0).
Our project's `minSdk = 29` (Android 10, confirmed in
`android/app/build.gradle.kts`). No conflict — we are four API levels above the minimum.

**Conflict check**: `flutter_secure_storage` is a Java-only Android plugin with no native C/C++
code — it writes only to `SharedPreferences` + Android Keystore (pure Java API layer). No
overlap with `flutter_gemma`'s LiteRT-LM native binary (`libliteRT*.so`) or `drift`'s sqlite3
JNI. No dependency on Jetpack Crypto (removed in 10.0.0), which was the source of previous
`EncryptedSharedPreferences` version-constraint conflicts.

**Seam design (Principle VII)**: define `SecureKeyStore` in
`lib/domain/services/secure_key_store.dart` (interface only — no plugin import). Implement as
`FlutterSecureKeyStore` in `lib/infrastructure/network/flutter_secure_key_store.dart`.
Import `flutter_secure_storage` ONLY in the implementation file. The `check_plugin_seam.sh`
script gains a new rule for `flutter_secure_storage`. Settings widgets read/write the key via
the interface only, injected via Riverpod.

**Migration note**: `encryptedSharedPreferences: true` (the old `AndroidOptions` flag) is
deprecated in 10.x. Do NOT pass it. The default constructor is correct for fresh installs;
existing installs with data written under the old mechanism (none exist — this is a new feature)
do not require migration.

---

## R4 — Tavily API contract

**Endpoint**: `POST https://api.tavily.com/search`

**Authentication**: HTTP header `Authorization: Bearer <api_key>`. The key goes in the `Bearer`
header, NOT in the JSON body. This is the current Tavily v2 API authentication model (confirmed
from docs.tavily.com June 2026). The key stored in `flutter_secure_storage` is read at call
time and added to the request header inside `NetworkResearchService` only — it never enters
the SQLite DB, log stream, or the model's context (FR-003, FR-015/SC-015).

**Request JSON (minimal call)**:
```json
{
  "query": "<string, required, ≤400 chars per FR-031>",
  "max_results": 3,
  "search_depth": "basic",
  "include_answer": false,
  "include_images": false
}
```
`max_results = 3` is the feature's hard limit (FR-010: handler limits to top 3). `search_depth
= "basic"` for low latency. `include_answer = false` — we want the raw `results` array, not
Tavily's own LLM-generated summary (the on-device model provides the synthesis). All other
fields (`include_raw_content`, `time_range`, `include_images`, etc.) default to false/null —
not sent.

**Response schema** (relevant fields; confirmed from docs.tavily.com endpoint reference):
```json
{
  "query": "string",
  "results": [
    {
      "title": "string",
      "url": "string",
      "content": "string",  // pre-extracted clean text — THIS is the field name (not "snippet")
      "score": 0.95
    }
  ],
  "response_time": 1.23
}
```
The `content` field (Tavily's name) maps directly to the tool-result schema `{title, url,
content, score}` with no renaming (FR-010: "no internal renaming to 'snippet' is permitted").
Top-level `answer` is ignored (not requested). `raw_content` is NOT requested (we use Tavily's
pre-extracted `content`).

**Error taxonomy mapping**:

| HTTP status | Tavily meaning | Feature error type |
|---|---|---|
| 401 | missing or invalid API key | `KeyInvalidError` (subtype of `ProviderError`) |
| 403 | key revoked / forbidden | `KeyInvalidError` |
| 429 | rate limit exceeded | `RateLimitError` (subtype of `ProviderError`) |
| 432 | plan/key usage limit | `RateLimitError` |
| 433 | pay-as-you-go limit | `RateLimitError` |
| 400 | bad request (bad params) | `ProviderError` |
| 5xx | server error | `ProviderError` |
| socket / DNS failure | offline or Tavily down | `OfflineError` if no connectivity, else `ProviderError` |
| request timeout | wall-clock exceeded | `TimeoutError` |

The 432/433 codes (plan limit exhausted) are treated as `RateLimitError` in the plain-language
chip message (user sees "tavily limit reached — check your plan"). The implementation reads
`response.statusCode` before parsing the body; no body parsing is attempted on 4xx/5xx. The
`NetworkResearchService.search()` method throws the typed error subclass; callers (the tool
handler) catch and map to the `ToolOutcome.failure` taxonomy.

---

## R5 — Connectivity check: catch `SocketException` + pre-flight via `InternetAddress.lookup`

**Decision**: do NOT add `connectivity_plus`. Detect offline via a lightweight pre-flight probe
(`InternetAddress.lookup('api.tavily.com')`) wrapped in a try/catch on `SocketException` /
`OSError`, with a configurable `kConnectivityTimeoutMs = 3000`. This runs before both the
Tavily call and the `fetch_page` GET. Any `SocketException` on the actual HTTP call (regardless
of the pre-flight) also maps to `OfflineError` if the lookup also fails, or `FetchDomainError`
if only the target site is unreachable.

**Why not `connectivity_plus`**: version 7.1.1 (latest as of June 2026) explicitly documents
that "you should not rely on the current connectivity status to decide whether you can reliably
make a network request" — it detects connection TYPE (WiFi/mobile), not internet reachability.
A device behind a captive portal shows WiFi connected but cannot reach Tavily. Additionally,
its Android Gradle Plugin requirement (`AGP >= 8.12.1`, Gradle wrapper `>= 8.13`) may conflict
with our Gradle setup (see the `agp9-flutter-gradle-dsl-migration` memory entry; our AGP was
already a source of pain). Adding a transitive Gradle version constraint for a feature we do not
need is unjustified.

**Lean alternative** (`dart:io` only): `InternetAddress.lookup(hostname)` throws `SocketException`
when the OS has no route to host; returns within milliseconds on airplane mode (the OS denies the
socket at the kernel level, not a network round-trip). On success, the actual HTTP call proceeds
normally. Any exception from the HTTP call itself (including mid-request disconnection) is caught
in the same try/catch block and reclassified by error type:
- `SocketException` (ENETUNREACH / EHOSTUNREACH / ENOTCONN) → `OfflineError`
- `SocketException` (ECONNREFUSED / ETIMEDOUT for target site) → `FetchDomainError`
- `TimeoutException` (Future.timeout) → `TimeoutError`
- HTTP 4xx/5xx → `ProviderError` or `FetchDomainError` depending on call type

This is zero new dependencies and covers the spec's FR-019/FR-034/SC-004 offline degradation
requirements cleanly.

---

## R6 — Tool registration seam: web tools in `ToolRegistry.webTools` + triple gate

**Decision** (mirrors 004 `deviceTools` / 005 `memoryTools` split): add a `webTools` list to
`ToolRegistry` containing `web_search` and `fetch_page`. The session provider composes the
declared list as:

```
deviceTools (if functionCalling)
+ memoryTools (if functionCalling && memoryEnabled)
+ webTools    (if functionCalling && effectiveWebEnabled && hasValidKey)
```

The triple gate (`functionCalling` AND `effectiveWebEnabled` AND `hasValidKey`) is the
structural implementation of FR-006. `effectiveWebEnabled` resolves the three-state
`webAccessOverride` per FR-007 (null → global default; `explicitly-on` / `explicitly-off`
override in either direction).

**Session recreation**: toggling `webAccessOverride` on an open conversation MUST recreate the
chat session (FR-032), identical to the 005 `startSession` pattern. Tool declarations are baked
into the LiteRT-LM session at `createConversation`; the seam's existing `startSession` method
is reused (R2 of the 005 research).

**Seam guard**: `webTools` are ONLY declared inside `NetworkResearchService`'s handler; if
`NetworkResearchService` is called without a valid key at runtime (a coding error), it throws
`StateError` — the same structural guard used in 004/005 for capability mismatches.

---

## R7 — Persistence: drift v5 → v6 migration (additive, house style)

**Decision**: new drift migration adds two columns via `m.addColumn` (house pattern: additive,
no data loss):

1. `conversations.webAccessOverride` — nullable TEXT (enum name: `inherit` / `on` / `off`);
   default NULL (= inherit-global). Existing rows remain NULL.
2. `app_settings.webAccessEnabled` — BOOL (default false). Existing row defaults to false.

No new tables. No source URL persistence table — source URLs are stored as a compact JSON array
inside the existing `tool_result` column (the 004/005 `role='tool'` message row), consistent
with Decision 4 (FR-024): persist call metadata + source URLs, NOT body text.

**Migration version**: 5 → 6 (005 left the DB at schemaVersion 5).

**Test-seed gotcha** (house rule from project memory `drift-migration-test-seed-gotcha`): the
prior `migration_v5_test.dart` seed AND any earlier `migration_v*_test` seeds that touch
`conversations` or `app_settings` MUST be updated to include the two new columns (with their
defaults) and their `schemaVersion` asserts bumped to 6. Failure to do this silently breaks older
seeds. The `migration_v6_test.dart` seed covers the new v5→v6 step.

---

## R8 — NetworkResearchService seam layout

All network and extraction logic lives in `lib/infrastructure/network/`:

```
lib/infrastructure/network/
  network_research_service.dart          # abstract interface (domain import-safe)
  tavily_network_research_service.dart   # concrete impl; imports http + flutter_secure_storage
  html_extractor.dart                    # pure Dart extraction pipeline (no plugin imports)
  research_errors.dart                   # typed error classes (OfflineError, ProviderError, …)
```

`lib/domain/services/secure_key_store.dart` — abstract interface; concrete impl in
`lib/infrastructure/network/flutter_secure_key_store.dart`.

The `check_plugin_seam.sh` script gains import-guard rules for:
- `flutter_secure_storage` → allowed only in `lib/infrastructure/network/`
- `package:http` → allowed only in `lib/infrastructure/network/`

This mirrors the existing `flutter_gemma` / `record` / `audioplayers` / `battery_plus` guards
(Principle VII). No widget, provider, or domain class may import these directly.

---

## R9 — Token budget accounting for web tool declarations

The two new tools add ~80 tokens of declarations to the system instruction (measured estimate
from spike §3.1). The `ContextAssembler` gains a `webToolsReserveTokens` constant (~80) added
to the existing 004 tool-instruction reserve (40) and 005 memory reserve (311) when web tools
are declared. Running total with all features active:

| Slot | Tokens |
|---|---|
| Output reserve | 512 |
| 004 device tool instruction | ~40 |
| 005 memory block (max 20 facts) | ~174 |
| 005 memory capture instruction | ~86 |
| 006 web tool declarations | ~80 |
| **Remaining for chat history + turn** | **~1,076** |

A `web_search` tool result (3 results × ~300 chars content) costs ~305 tokens (spike §3.2),
leaving ~771 tokens for chat history + model reasoning — adequate for 2–3 prior turns. A
`fetch_page` result (≤ 2,000 chars = ~500 tokens) leaves ~576 tokens. Both fit; the hard
`ToolSpec.resultCharBound` guards enforce the ceilings at the handler level (FR-011, FR-014).

---

## Pinned versions (this feature's additions)

| Package | Version | Why |
|---|---|---|
| `http` | `^1.6.0` | Official Dart HTTP client; already transitive via background_downloader; lean scope; supports abort-trigger cancellation + Future.timeout wrapping for per-request timeouts. |
| `html` | `^0.15.6` | Pure-Dart HTML5 parser; latest stable on pub.dev June 2026; same version already implicit in spike §2.2 design; spike confirmed correct extraction on 10 pages without a readability package. |
| `flutter_secure_storage` | `^10.3.1` | Android Keystore-backed AES/GCM key storage for the Tavily BYOK key; minSdk 23 compatible with our minSdk 29; pure Java plugin, no native conflict with flutter_gemma/sqlite3; behind SecureKeyStore seam (Principle VII). |
| `flutter_gemma` | `^0.15.0` (0.15.3 installed) | UNCHANGED — spike findings are 0.15.3-specific; 0.16.x remains a model-load regression on the A34. |
| `connectivity_plus` | NOT ADDED | Detects connection TYPE only, not reachability; dart:io SocketException + InternetAddress.lookup covers FR-019/SC-004 with zero new deps or Gradle constraints. |

### Dependency conflict summary

No conflicts identified:

- `http ^1.6.0` is a pure-Dart package with no native code — cannot collide with flutter_gemma FFI or sqlite3 JNI.
- `html ^0.15.6` is a pure-Dart HTML parser — no native code.
- `flutter_secure_storage ^10.3.1` is a Java-only Android plugin using Android Keystore API and `SharedPreferences`. Its 10.x refactor removed the Jetpack Crypto dependency (`EncryptedSharedPreferences`) that previously caused AGP/Kotlin version constraint issues. No overlap with LiteRT-LM (`libliteRT*.so`), sqlite3 JNI, or any existing package in the stack.
- All three new packages require Dart `>=3.0.0` or `>=3.3.0`; our environment is Dart `3.10.7` / Flutter `3.44.1` — all constraints satisfied.
