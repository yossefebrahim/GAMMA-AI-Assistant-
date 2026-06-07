import 'package:meta/meta.dart';

/// A prior turn passed back to the model as context (FR-017).
///
/// Deliberately minimal — `isUser` + `text` — so the context assembler can hand the
/// `GemmaService` an ordered, sliding-window-trimmed history without leaking persistence or
/// presentation types into the seam.
@immutable
class ChatTurn {
  const ChatTurn({required this.isUser, required this.text});

  /// Convenience constructor for a user turn.
  const ChatTurn.user(this.text) : isUser = true;

  /// Convenience constructor for an assistant turn (including stopped-partial turns).
  const ChatTurn.assistant(this.text) : isUser = false;

  final bool isUser;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ChatTurn && other.isUser == isUser && other.text == text;

  @override
  int get hashCode => Object.hash(isUser, text);
}
