import 'package:drift/drift.dart';

// Generated drift row classes are renamed (`*Row`) so they never collide with the pure-Dart
// domain entities (Conversation, Message, ModelInstall, AppSettings, Memory). The repository layer
// maps between rows and entities. Schema mirrors data-model.md.

@DataClassName('ConversationRow')
class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Derived from the first user message, ≤40 chars (FR-021); null until the first message.
  TextColumn get title => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Primary sort key for the history list (most-recent first).
  DateTimeColumn get updatedAt => dateTime()();

  /// Per-conversation web-access override (006, schema v6). NULL = inherit the global
  /// `webAccessEnabled` setting; 'on' / 'off' force web tools on or off for this conversation
  /// (FR-007, three-state, data-model §1). Added by the v5→v6 migration as nullable, so existing
  /// rows stay valid with NULL (= inherit).
  TextColumn get webAccessOverride => text().nullable()();
}

@DataClassName('MessageRow')
@TableIndex(
  name: 'idx_messages_conversation',
  columns: {#conversationId, #sequence},
)
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// FK → conversations.id, ON DELETE CASCADE (FR-022).
  IntColumn get conversationId =>
      integer().references(Conversations, #id, onDelete: KeyAction.cascade)();

  /// `MessageRole.name` — 'user' | 'assistant' | 'tool' (the 'tool' value added in schema v4,
  /// domain-enforced — no SQL CHECK, consistent with existing role handling).
  TextColumn get role => text()();

  TextColumn get content => text()();

  /// Monotonic per conversation; defines turn order.
  IntColumn get sequence => integer()();

  DateTimeColumn get createdAt => dateTime()();

  /// `MessageStatus.name` — 'complete' | 'streaming' | 'stoppedPartial'.
  TextColumn get status => text()();

  /// Absolute app-private path of the attached image file (002, schema v2). Null for text-only
  /// turns and all assistant turns. The bytes live as a file under `…/images/`; only the path is
  /// stored here (R5). Added by the v1→v2 migration as nullable, so existing rows stay valid.
  TextColumn get imagePath => text().nullable()();

  /// Best-effort MIME type of [imagePath] (e.g. `image/jpeg`), for rendering/debugging (002,
  /// schema v2). Null when there is no image.
  TextColumn get imageMimeType => text().nullable()();

  /// Absolute app-private path of the attached voice clip (003, schema v3). Null for text-only
  /// turns and all assistant turns; exclusive with [imagePath] (audio XOR image, spec Q3 —
  /// enforced upstream). The bytes live as a file under `…/audio/`; only the path is stored here
  /// (R6). Added by the v2→v3 migration as nullable, so existing rows stay valid.
  TextColumn get audioPath => text().nullable()();

  /// Best-effort MIME type of [audioPath] (`audio/wav`), for rendering/debugging (003, schema
  /// v3). Null when there is no audio.
  TextColumn get audioMimeType => text().nullable()();

  /// Function calling (004, schema v4). A `role='tool'` row records ONE tool invocation: the
  /// model-facing tool name, the attempted/validated args, the lifecycle status, and the bounded
  /// result. All four are NULL for user/assistant rows (domain XOR invariant, data-model §1); a
  /// tool row never carries image/audio. Added by the v3→v4 migration as nullable, so existing
  /// rows stay valid (FR-013/FR-019).

  /// The tool name (snake_case registry id). Non-null iff role == tool.
  TextColumn get toolName => text().nullable()();

  /// The model's arguments as JSON. Non-null iff role == tool (may be `{}`).
  TextColumn get toolArgs => text().nullable()();

  /// `ToolCallStatus.name` — 'running' | 'success' | 'error' | 'skipped'. Non-null iff role ==
  /// tool. `running` is transient; a startup sweep finalizes any stale `running` row.
  TextColumn get toolStatus => text().nullable()();

  /// The result as JSON — the success payload, or `{error: reason}` otherwise. Bounded per-tool
  /// (≤ 4,400 absolute ceiling, app-enforced). Null while `running`.
  TextColumn get toolResult => text().nullable()();
}

@DataClassName('ModelInstallRow')
class ModelInstalls extends Table {
  /// Constant model id, e.g. `gemma-4-e2b`.
  TextColumn get id => text()();

  /// `ModelInstallState.name`.
  TextColumn get state => text()();

  TextColumn get filePath => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  DateTimeColumn get installedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('AppSettingsRow')
class AppSettingsTable extends Table {
  /// Single-row table; id is always 1.
  IntColumn get id => integer()();

  /// `AppThemeMode.name` — 'dark' | 'light' | 'system'.
  TextColumn get themeMode => text()();

  DateTimeColumn get licenseAcknowledgedAt => dateTime().nullable()();

  /// Whether durable memory is on (005, schema v5). Default **true** (Clarifications Q3); when off,
  /// facts are neither captured nor injected (management still works, FR-016). Added by the v4→v5
  /// migration with a default of 1 so the existing single row stays valid (data-model §2).
  BoolColumn get memoryEnabled => boolean().withDefault(const Constant(true))();

  /// Whether web research tools are globally enabled (006, schema v6). Default **false** (off by
  /// default — SC-001, Decision 1); individual conversations may override via
  /// [Conversations.webAccessOverride]. Added by the v5→v6 migration with DEFAULT 0 so the
  /// existing single row stays valid (data-model §2).
  BoolColumn get webAccessEnabled =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Durable, app-global facts about the user (005, schema v5). Only `active` rows are injected into
/// the model's system message or shown in settings; supersede/forget/clear flip `active` to false
/// (soft-delete, data-model §2/§3). Facts outlive the conversation they were captured in —
/// `sourceConversationId` is `ON DELETE SET NULL`, NOT cascade (Clarifications Q1).
@DataClassName('MemoryRow')
@TableIndex(
  name: 'idx_memories_active',
  columns: {#active, #category, #updatedAt},
)
class Memories extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Short canonical third-person statement about the user; ≤ 80 chars (R4, validated on capture).
  TextColumn get fact => text()();

  /// `MemoryCategory.name` — 'identity' | 'work' | 'preferences' | 'other'. Drives grouping in the
  /// injected facts block and the settings screen (the same set, FR-015).
  TextColumn get category => text()();

  DateTimeColumn get createdAt => dateTime()();

  /// Refreshed on supersede/edit; the recency key for block ordering + cap (data-model §1/§3).
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft-delete / supersede flag — only `active` rows are injected or listed (default true).
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  /// The conversation it was captured in; null for manually-added facts. `ON DELETE SET NULL` so
  /// deleting a conversation keeps the fact but nulls provenance (facts are durable/app-global —
  /// contrast with messages, which cascade-delete with their conversation).
  IntColumn get sourceConversationId => integer().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.setNull,
  )();
}
