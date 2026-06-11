import 'package:drift/drift.dart';

// Generated drift row classes are renamed (`*Row`) so they never collide with the pure-Dart
// domain entities (Conversation, Message, ModelInstall, AppSettings). The repository layer maps
// between rows and entities. Schema mirrors data-model.md.

@DataClassName('ConversationRow')
class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Derived from the first user message, ≤40 chars (FR-021); null until the first message.
  TextColumn get title => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Primary sort key for the history list (most-recent first).
  DateTimeColumn get updatedAt => dateTime()();
}

@DataClassName('MessageRow')
@TableIndex(name: 'idx_messages_conversation', columns: {#conversationId, #sequence})
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

  @override
  Set<Column<Object>> get primaryKey => {id};
}
