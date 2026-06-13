# Contract — ToolRegistry / SchemaValidator / ToolDispatcher deltas (006)

Extends the 004 contract and the 005 delta contract. All three components stay plugin-free. This
feature ADDS two tools (`web_search`, `fetch_page`), one new validator keyword (`format: uri`),
and two handlers — it does NOT change the dispatcher's validate → handler → typed `ToolOutcome`
pipeline.

---

## ToolRegistry (`lib/core/tools/tool_registry.dart`) — now eight tools, four views

```dart
abstract final class ToolRegistry {
  static const List<ToolSpec> deviceTools;  // 004: get_device_info, summarize_clipboard, set_theme, set_timer
  static const List<ToolSpec> memoryTools;  // 005: remember_fact, forget_fact
  static const List<ToolSpec> webTools;     // 006: web_search, fetch_page
  static const List<ToolSpec> specs;        // deviceTools + memoryTools + webTools (byName scans this)
  static ToolSpec? byName(String name);
  static const String systemInstruction;    // 004 device tool-use instruction (unchanged)
}
```

Registry-sanity test updated: names unique across all eight, every `parameters` self-validates
against the (extended) validator subset, descriptions non-empty, `kind` set. `web_search` and
`fetch_page` are `ToolKind.stateChanging` (network egress — consistent with codebase convention
that marks egress intent, not app-state mutation; `readOnly` is reserved for pure on-device reads).
The session provider composes the declared list by flag (R6 of research.md):

```
deviceTools  (if functionCalling)
+ memoryTools (if functionCalling && memoryEnabled)
+ webTools    (if functionCalling && effectiveWebEnabled && hasValidKey)
```

---

## Tool specs (authoritative JSON schemas)

### `web_search`

```dart
ToolSpec(
  name: 'web_search',
  description: 'Search the web via Tavily and return the top 3 results as '
      '{title, url, content, score} objects. Use for current events, live '
      'documentation, or any question that benefits from up-to-date sources. '
      'Do NOT call for arithmetic, in-context questions, or anything answerable '
      'from your own knowledge. One call per turn only.',
  kind: ToolKind.stateChanging, // marks network egress intent (not app-state mutation — consistent with codebase convention)
  parameters: {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'The search query. Non-empty, ≤ 400 characters. Plain natural-language '
            'question or keyword phrase.',
        'minLength': 1,
        'maxLength': 400,
      },
    },
    'required': ['query'],
    'additionalProperties': false,
  },
  resultCharBound: 2000, // dispatcher applies this ceiling to the serialised result
)
```

**Result shape returned to the model** (as a JSON string inside the tool-result block):

```json
{
  "results": [
    { "title": "string", "url": "string", "content": "string", "score": 0.0 }
  ]
}
```

Zero-results case: `{"results": [], "note": "no results found — answering from own knowledge"}`.

The field name `content` maps directly from Tavily's response field — it MUST NOT be renamed
to `snippet` or any other alias (FR-010). The `resultCharBound = 2000` applies to the FULL
serialised JSON string above; the handler pre-truncates each `content` value before
serialisation to stay within budget.

### `fetch_page`

```dart
ToolSpec(
  name: 'fetch_page',
  description: 'Fetch a URL and return the readable extracted text. Use when the '
      'user explicitly asks to read a specific page or when you need the full '
      'article text from a URL already in context. The page is fetched DIRECTLY '
      'from the target website (not via Tavily). One call per turn only. Do NOT '
      'chain fetch_page immediately after web_search in the same turn.',
  kind: ToolKind.stateChanging,
  parameters: {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description':
            'The full URL to fetch. Must start with http:// or https://. '
            'Must be a well-formed URL (scheme + host + optional path). '
            'Maximum 2,048 characters.',
        'format': 'uri',    // NEW validator keyword (see SchemaValidator section)
        'maxLength': 2048,
      },
    },
    'required': ['url'],
    'additionalProperties': false,
  },
  resultCharBound: 2000, // authoritative tool-result bound (FR-014); NOT 1,500
)
```

**Result shape returned to the model**:

```json
{
  "url": "string",
  "text": "string (≤ 2,000 chars, possibly truncated)",
  "truncated": false
}
```

When `truncated == true`, `text` ends with `[truncated: N items remaining]`.

---

## STRICT argument validation

All validation runs in `SchemaValidator` BEFORE the handler is invoked (guarantee 1 of the 004
dispatcher contract). Invalid args → `ToolOutcome.failure` with a plain-language reason; the
handler is never reached.

### `web_search` validation rules (applied in order; first failure wins)

| Rule | Condition | Error message |
|---|---|---|
| Required | `query` key absent | "query is required" |
| Type | `query` not a string | "query must be a string" |
| Non-empty | `query.trim().isEmpty` | "query is empty" |
| `maxLength` | `query.length > 400` | "query too long — max 400 characters" |
| Unknown keys | any key other than `query` present | "unknown argument: \<key>" |

The 400-char bound applies to the raw string length (not trimmed), consistent with FR-031.
Whitespace-only queries pass `minLength` but fail the `trim().isEmpty` guard — reported as
"query is empty" (FR-031).

### `fetch_page` validation rules (applied in order; first failure wins)

| Rule | Condition | Error message |
|---|---|---|
| Required | `url` key absent | "url is required" |
| Type | `url` not a string | "url must be a string" |
| `maxLength` | `url.length > 2048` | "url too long — max 2,048 characters" |
| `format: uri` | `Uri.tryParse(url)` returns null or `!uri.hasScheme` | "url is not a valid URI" |
| Scheme allowlist | `uri.scheme != 'http' && uri.scheme != 'https'` | "url scheme must be http or https" |
| Unknown keys | any key other than `url` present | "unknown argument: \<key>" |

A URL that passes all rules but leads to a network failure is NOT a validation error — it
surfaces as a `FetchDomainError` chip after the fetch attempt (FR-015 boundary: validation
rejects structurally invalid URLs; domain failures are handler-level).

---

## SchemaValidator delta — one new keyword: `format: uri`

The existing 004/005 validator subset (`object / properties / required / enum / string /
integer / number / boolean / minLength / maxLength / minimum / maximum / additionalProperties`)
gains one new keyword:

- **`format: uri`** (for `type: string`): parse with `Uri.tryParse(value)`. Reject if the
  result is `null` OR if `!parsed.hasScheme` OR if `!parsed.hasAuthority`. The
  scheme-allowlist check (`http`/`https` only) is a SEPARATE validation step applied after
  `format` passes — it is NOT folded into the `format` keyword, so the error messages are
  distinct ("not a valid URI" vs "scheme must be http or https").

No other new keywords are added. The registry-sanity test exercises `format: uri` via the
`fetch_page` spec's `url` parameter.

---

## ToolDispatcher (`lib/domain/services/tool_dispatcher.dart`) — unchanged pipeline, two new handlers

The dispatcher's validate → handler → typed outcome pipeline (004 contract) is unchanged.
`ToolSpec.resultCharBound` enforcement (`_applyBound`) applies to both web tools at 2,000 chars
— the same mechanism used by 004/005 tools. Two new handler bindings in
`toolHandlersProvider`:

| Name | Handler call | Outcome mapping |
|---|---|---|
| `web_search` | `NetworkResearchService.search(query)` | `List<SearchResult>` → `ToolSuccess(serialisedJson)`; `ResearchError` → `ToolFailure(plainLangMessage)` |
| `fetch_page` | `NetworkResearchService.fetchPage(url)` | `FetchResult` → `ToolSuccess(serialisedJson)`; `ResearchError` → `ToolFailure(plainLangMessage)` |

**Dispatcher coercion / bounding behavior**:

1. **`resultCharBound = 2000`**: after the handler returns a `ToolSuccess`, the dispatcher's
   `_applyBound` trims the serialised result string to 2,000 chars if it exceeds the bound.
   For `web_search` the handler pre-truncates content values before serialising, so
   `_applyBound` acts as a safety net rather than the primary truncation. For `fetch_page` the
   seam already limits `FetchResult.extractedText` to 2,000 chars — `_applyBound` verifies the
   ceiling is respected.
2. **No integer-double coercion needed**: neither `web_search` nor `fetch_page` takes an
   integer argument, so the 004/005 `id`-as-`double` coercion is not relevant here.
3. **One-round-trip-per-turn (FR-028)**: if the model emits a second tool call on the resumed
   stream (a `ToolCallRequested` event after `resumeWithToolResult` has been called once), the
   dispatcher chips-and-skips it with the message "call skipped — one tool per turn", consistent
   with 004 §4.3. This applies if the model tries to call `fetch_page` immediately after
   `web_search` in the same turn (intra-turn chaining is architecturally blocked — spike §4.3).
4. **Handler exceptions → `ToolFailure`** (guarantee 2 of 004 contract, extended): any
   uncaught exception from the web handler (including `ResearchError` subtypes) is caught and
   mapped to `ToolFailure(message)`. The dispatcher never throws.

### Error → plain-language message mapping

| `ResearchError` subtype | `ToolFailure` message (shown in red chip) |
|---|---|
| `OfflineError` | "offline — no connection" |
| `KeyInvalidError` | "tavily key invalid — check Settings" |
| `RateLimitError` | "tavily limit reached — check your plan" |
| `ProviderError` (other) | "provider error (HTTP \<statusCode>)" |
| `FetchDomainError` | "could not reach \<domain> — check the URL or try later" |
| `TimeoutError` | "request timed out — try again" |
| `ParseError` | "could not extract text from page" |

---

## Gating contract (triple gate)

**Given** the session provider is computing the tool declaration list for a conversation,
**Then** `webTools` (`web_search` + `fetch_page`) are included in the declared list IF AND
ONLY IF ALL THREE conditions are true simultaneously (FR-006):

1. `capabilities.functionCalling == true` (model is tool-capable)
2. `SecureKeyStore.hasValidKey() == true` (a non-empty Tavily key is stored)
3. `effectiveWebAccess(conversation) == true`, where effective access resolves as (FR-007):
   - `webAccessOverride == explicitly-on` → `true` (regardless of global setting)
   - `webAccessOverride == explicitly-off` → `false` (regardless of global setting)
   - `webAccessOverride == inherit` (NULL) → value of global `webAccessEnabled` flag

If ANY condition is false, `webTools` is an EMPTY list — the tools are STRUCTURALLY ABSENT
from the session, not refused at runtime. This matches the 004 capability-seam `StateError`
guard pattern (tools not declared ⇒ model cannot call them ⇒ no chip appears).

**Mid-conversation toggle change (FR-032)**: when the per-conversation `webAccessOverride` is
changed while a LiteRT-LM session is live, the controller MUST call
`GemmaService.startSession(systemInstruction: ...)` (close-then-recreate, per the 005 pattern)
with the updated tool list BEFORE the next user turn. Tool declarations are baked into the
session at `createConversation`; a live session cannot be patched in place.

**`StateError` guard in the handler**: if `web_search` or `fetch_page` is dispatched to the
handler but `SecureKeyStore.hasValidKey()` returns false (a coding error — the gate should have
prevented declaration), the handler throws `StateError('web tools called without a valid key')`.
This mirrors the 004/005 `StateError` structural guard.

---

## Chip recipient rule (Constitution v2.0.0 Principle I, FR-022)

Every web tool call renders a chip naming the TRUE external recipient BEFORE the network call
completes (FR-023 optimistic render):

| Tool | Chip label pattern | Recipient named | Rationale |
|---|---|---|---|
| `web_search` | `WEB_SEARCH · Tavily` | Tavily | The request goes to `api.tavily.com` — Tavily is the named recipient |
| `fetch_page` | `FETCH_PAGE · [domain]` | Target website hostname | The request goes DIRECTLY to the target site, NOT via Tavily; the chip names the actual destination (e.g. `FETCH_PAGE · flutter.dev`) |

`[domain]` is `Uri.parse(url).host` (e.g. `flutter.dev`, `en.wikipedia.org`). It is extracted
from the validated `url` argument at chip-render time, before the fetch call is made.

These two chip labels are DISTINCT on purpose — conflating them (e.g. labelling `fetch_page`
with "Tavily") would violate Constitution v2.0.0 Principle I (named recipient per egress path)
and FR-002's disclosure requirement that `fetch_page` makes a direct request to the target
website.

---

## Handler services (`lib/features/chat/tool_handler_providers.dart`)

`web_search` and `fetch_page` bind to `networkResearchServiceProvider`; the handler reads the
service via Riverpod injection (same in-provider closure pattern as the 005 memory handlers).
Each is fakeable via `FakeNetworkResearchService`. No new plugin import in the handler file —
`networkResearchServiceProvider` returns the `NetworkResearchService` abstract interface;
`flutter_secure_storage` and `package:http` remain confined to `lib/infrastructure/network/`.

`check_network_seam.sh` gains a rule: `lib/features/` must not import `package:http` or
`flutter_secure_storage` directly.

---

## Congruence guarantee (extends 004/005)

**When** `webTools` are declared (triple gate = true), the `toolHandlersProvider` map covers
exactly `web_search` and `fetch_page` in addition to the device and memory tools (≤ 8 total).
**When** the triple gate is false, `web_search` and `fetch_page` are ABSENT from both the
declaration list AND the handler map. Registry-sanity test is updated to cover all eight names,
verify uniqueness, and assert the congruence invariant across all gate combinations.
