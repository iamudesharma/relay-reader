import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_reader/lfm3.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LlamaEngineProvider()],
    );
    Lfm3Model.markReady();
  });

  testWidgets('LFM3 completes a long dialogue section', (tester) async {
    if (!await Lfm3Model.isDownloaded()) return;
    await Lfm3Model.load();
    final text = List.generate(50, (index) {
      final speaker = index.isEven ? 'Elizabeth' : 'Mr. Darcy';
      return '“Line ${index + 1} of the conversation, spoken aloud.” '
          'said $speaker.';
    }).join('\n\n');
    final suggestions = await Lfm3Analyzer.analyze(
      text: text,
      cast: const ['Elizabeth', 'Mr. Darcy'],
      lead: 'Elizabeth',
    );
    expect(suggestions.length, greaterThan(20));
    await Lfm3Model.unload();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
