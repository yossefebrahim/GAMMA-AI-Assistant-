import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:meta/meta.dart';

/// A prior turn passed back to the model as context (FR-017), optionally carrying an [image] so a
/// follow-up keeps referring to an earlier image without re-attaching (FR-015/FR-016).
///
/// Deliberately minimal — `isUser` + `text` (+ optional `image`) — so the context assembler can
/// hand the `GemmaService` an ordered, sliding-window-trimmed history without leaking persistence
/// or presentation types into the seam.
@immutable
class ChatTurn {
  const ChatTurn({required this.isUser, required this.text, this.image});

  /// Convenience constructor for a user turn (optionally image-bearing).
  const ChatTurn.user(this.text, {this.image}) : isUser = true;

  /// Convenience constructor for an assistant turn (including stopped-partial turns). Assistant
  /// turns never carry an image.
  const ChatTurn.assistant(this.text)
      : isUser = false,
        image = null;

  final bool isUser;
  final String text;

  /// The image to replay with this turn (FR-015/FR-016). Null for text-only and assistant turns.
  final ImageInput? image;

  @override
  bool operator ==(Object other) =>
      other is ChatTurn &&
      other.isUser == isUser &&
      other.text == text &&
      other.image == image;

  @override
  int get hashCode => Object.hash(isUser, text, image);
}
