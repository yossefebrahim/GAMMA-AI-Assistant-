import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:meta/meta.dart';

/// A prior turn passed back to the model as context (FR-017), optionally carrying an [image] or an
/// [audio] clip so a follow-up keeps referring to earlier media without re-attaching
/// (FR-015/FR-016; 003 FR-016/FR-017).
///
/// A user turn carries **at most one** of `image`/`audio` (spec 003 Q3); assistant turns never
/// carry media. Deliberately minimal so the context assembler can hand the `GemmaService` an
/// ordered, sliding-window-trimmed history without leaking persistence or presentation types into
/// the seam.
@immutable
class ChatTurn {
  const ChatTurn({required this.isUser, required this.text, this.image, this.audio});

  /// Convenience constructor for a user turn (optionally media-bearing).
  const ChatTurn.user(this.text, {this.image, this.audio}) : isUser = true;

  /// Convenience constructor for an assistant turn (including stopped-partial turns). Assistant
  /// turns never carry media.
  const ChatTurn.assistant(this.text)
      : isUser = false,
        image = null,
        audio = null;

  final bool isUser;
  final String text;

  /// The image to replay with this turn (FR-015/FR-016). Null for text-only and assistant turns.
  final ImageInput? image;

  /// The voice clip to replay with this turn (003 FR-016/FR-017). Null for text-only and
  /// assistant turns; exclusive with [image].
  final AudioInput? audio;

  @override
  bool operator ==(Object other) =>
      other is ChatTurn &&
      other.isUser == isUser &&
      other.text == text &&
      other.image == image &&
      other.audio == audio;

  @override
  int get hashCode => Object.hash(isUser, text, image, audio);
}
