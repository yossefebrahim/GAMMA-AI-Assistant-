import 'package:ai_assistant/domain/services/web_url_launcher.dart';

/// In-memory [WebUrlLauncher] test double (006 T034). Records every URL a source chip tap requested
/// to open, so widget tests can assert the browser hand-off without firing a real Android intent.
class FakeWebUrlLauncher implements WebUrlLauncher {
  /// Every URL passed to [open], in tap order.
  final List<String> opened = [];

  @override
  Future<void> open(String url) async {
    opened.add(url);
  }
}
