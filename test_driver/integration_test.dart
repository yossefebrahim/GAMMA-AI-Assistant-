// THROWAWAY SPIKE driver (003 Phase 0) — lets the on-device spike run via `flutter drive`,
// which (unlike `flutter test integration_test/...`) does NOT uninstall the app and wipe its
// data (the downloaded 2.4 GB model) around the run. Remove with the spike.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
