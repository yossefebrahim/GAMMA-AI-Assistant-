import 'package:ai_assistant/app/app.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart'
    show installGemmaLogFilter;
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

/// Bundled-font OFL license assets to register with Flutter's [LicenseRegistry] (R6 / OFL terms).
const Map<String, String> _fontLicenseAssets = {
  'Space Grotesk': 'assets/fonts/SpaceGrotesk-OFL.txt',
  'Space Mono': 'assets/fonts/SpaceMono-OFL.txt',
  'Pixelify Sans': 'assets/fonts/PixelifySans-OFL.txt',
};

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // flutter_gemma logs several lines per streamed token (release builds included) — drop that
  // noise before it floods the log channel while frames are racing (see the gemma seam).
  installGemmaLogFilter();

  // Offline-first (Principle I/II): never fetch fonts over the network — the app ships them as
  // bundled assets. If a glyph isn't bundled it falls back locally, it does NOT hit Google Fonts.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Surface the bundled fonts' OFL licenses in the app's license page (OFL requires shipping them).
  LicenseRegistry.addLicense(() async* {
    for (final entry in _fontLicenseAssets.entries) {
      final license = await rootBundle.loadString(entry.value);
      yield LicenseEntryWithLineBreaks([entry.key], license);
    }
  });

  runApp(const ProviderScope(child: GemmaAssistantApp()));
}
