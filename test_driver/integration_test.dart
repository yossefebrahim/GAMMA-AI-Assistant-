// Reliability-gate driver (004 T057) — lets the on-device 20-prompt correct-call suite run via
// `flutter drive`, which (unlike `flutter test integration_test/...`) does NOT uninstall the app
// and wipe its data (the downloaded 2.4 GB model + DB) around the run. DO NOT `flutter test` this.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
