import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/tts_benchmark_test.dart' show registerTtsBenchmark;

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationSupportDirectory();
  registerTtsBenchmark(
    includeSupertonic: true,
    useAppModels: true,
    outputDirectory: '${root.path}/benchmarks/all-tts',
  );
}
