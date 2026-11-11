import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// A paragraph-level speaker suggestion from the experimental LFM3 model.
class Lfm3Suggestion {
  const Lfm3Suggestion({required this.paragraph, required this.speaker});

  final int paragraph;
  final String speaker;
}

class Lfm3Exception implements Exception {
  const Lfm3Exception(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The downloadable, text-only LFM3 model used by the optional experimental
/// speaker-suggestion feature. The model is never downloaded until the reader
/// explicitly enables the feature.
abstract final class Lfm3Model {
  static const fileName = 'LFM3-1.7B-Q4_K_M.gguf';
  static const displaySize = '1.1 GB';
  static const expectedBytes = 1099627808;
  static const downloadUrl = String.fromEnvironment(
    'LFM3_MODEL_URL',
    defaultValue:
        'https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/'
        'LFM3-1.7B-Q4_K_M.gguf?download=true',
  );

  static InferenceModel? _model;
  static bool _packageReady = false;

  static bool get supported =>
      _packageReady && (Platform.isIOS || Platform.isMacOS);

  /// Called once after Flutter Edge AI registers its llama.cpp engine.
  static void markReady() => _packageReady = true;

  static Future<bool> isDownloaded() async {
    if (!supported) return false;
    try {
      return await FlutterEdgeAi.isModelInstalled(fileName);
    } catch (_) {
      return false;
    }
  }

  /// Downloads and installs the model through Flutter Edge AI. Call only after
  /// an explicit user action. The package keeps partial downloads retryable.
  static Future<void> download({
    required void Function(int percent) onProgress,
  }) async {
    if (!supported) {
      throw const Lfm3Exception('LFM3 is not available on this platform.');
    }
    try {
      await FlutterEdgeAi.installModel(
            modelType: ModelType.general,
            fileType: ModelFileType.gguf,
          )
          .fromNetwork(
            downloadUrl,
            filename: fileName,
            expectedSize: expectedBytes,
          )
          .withProgress(onProgress)
          .install();
    } catch (error) {
      throw Lfm3Exception('The LFM3 model could not be installed: $error');
    }
  }

  static Future<InferenceModel> _load() async {
    if (!supported) {
      throw const Lfm3Exception('LFM3 is not available on this platform.');
    }
    if (!await isDownloaded()) {
      throw const Lfm3Exception('Download the LFM3 model first.');
    }
    try {
      return _model ??= await FlutterEdgeAi.getActiveModel(maxTokens: 8192);
    } catch (error) {
      throw Lfm3Exception('LFM3 could not be loaded: $error');
    }
  }

  static Future<void> load() async {
    await _load();
  }

  static Future<InferenceChat> _openChat(
    InferenceModel model,
    int maxTokens,
    ResponseFormat? responseFormat,
  ) => model.openChat(
    maxOutputTokens: maxTokens,
    enableThinking: false,
    responseFormat: responseFormat,
    systemInstruction:
        'You are a quotation attribution engine. Follow the requested JSON '
        'format exactly and do not explain.',
  );

  static Future<String> generate(
    String prompt, {
    int maxTokens = 512,
    ResponseFormat? responseFormat,
  }) async {
    final model = await _load();
    InferenceChat? chat;
    try {
      try {
        chat = await _openChat(model, maxTokens, responseFormat);
      } on ResponseFormatUnsupportedException {
        // Older runtimes may not enforce JSON schemas. Fall back to text.
        chat = await _openChat(model, maxTokens, null);
      }
      await chat.addQuery(Message.text(text: prompt, isUser: true));
      final output = StringBuffer();
      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) output.write(response.token);
      }
      return output.toString();
    } catch (error) {
      throw Lfm3Exception('LFM3 inference failed: $error');
    } finally {
      await chat?.close();
    }
  }

  static Future<void> unload() async {
    final model = _model;
    _model = null;
    try {
      await model?.close();
    } catch (_) {
      // The model is also released when the process exits.
    }
  }

  static Future<void> delete() async {
    await unload();
    try {
      await FlutterEdgeAi.uninstallModel(fileName);
    } catch (error) {
      throw Lfm3Exception('The LFM3 model could not be deleted: $error');
    }
  }
}

abstract final class Lfm3Analyzer {
  static const _maxChunkWords = 600;
  static const _maxQuotesPerChunk = 8;
  static const _maxOutputTokens = 1200;
  static const _contextParagraphs = 2;

  static final _format = ResponseFormat.jsonSchema({
    'type': 'array',
    'minItems': 1,
    'maxItems': 64,
    'items': {
      'type': 'object',
      'properties': {
        'paragraph': {'type': 'integer'},
        'speaker': {'type': 'string', 'minLength': 1, 'maxLength': 80},
      },
      'required': ['paragraph', 'speaker'],
      'additionalProperties': false,
    },
  });

  static Future<List<Lfm3Suggestion>> analyze({
    required String text,
    required Iterable<String> cast,
    String? lead,
    void Function(int done, int total)? onProgress,
  }) async {
    final paragraphs = text
        .replaceAll('\r\n', '\n')
        .split(RegExp(r'\n\s*\n'))
        .map((paragraph) => paragraph.trim().replaceAll('\n', ' '))
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.isEmpty) return const [];

    final chunks = <List<int>>[];
    var current = <int>[];
    var words = 0;
    var quotes = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      final count = paragraphs[i].split(RegExp(r'\s+')).length;
      final hasQuote =
          paragraphs[i].contains('“') || paragraphs[i].contains('"');
      if (current.isNotEmpty &&
          (words + count > _maxChunkWords ||
              quotes + (hasQuote ? 1 : 0) > _maxQuotesPerChunk)) {
        chunks.add(current);
        current = <int>[];
        words = 0;
        quotes = 0;
      }
      current.add(i);
      words += count;
      if (hasQuote) quotes++;
    }
    if (current.isNotEmpty) chunks.add(current);

    final known = cast
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .join(', ');
    final analysisChunks = <List<int>>[];
    for (final chunk in chunks) {
      final requestedIds = _quoteIds(paragraphs, chunk);
      if (requestedIds.isNotEmpty) analysisChunks.add(requestedIds.toList());
    }

    final suggestions = <int, String>{};
    var done = 0;
    for (final requestedIds in analysisChunks) {
      await _attribute(
        paragraphs: paragraphs,
        ids: requestedIds.toSet(),
        known: known,
        lead: lead,
        suggestions: suggestions,
      );
      done++;
      onProgress?.call(done, analysisChunks.length);
    }
    return [
      for (final entry in suggestions.entries)
        Lfm3Suggestion(paragraph: entry.key, speaker: entry.value),
    ]..sort((a, b) => a.paragraph.compareTo(b.paragraph));
  }

  static Set<int> _quoteIds(List<String> paragraphs, Iterable<int> indices) => {
    for (final index in indices)
      if (paragraphs[index].contains('“') || paragraphs[index].contains('"'))
        index,
  };

  /// Attributes a batch of paragraphs. If the model runs out of output room,
  /// split the batch and retry; this keeps longer chapters from failing with
  /// a single truncated JSON response.
  static Future<void> _attribute({
    required List<String> paragraphs,
    required Set<int> ids,
    required String known,
    required String? lead,
    required Map<int, String> suggestions,
  }) async {
    if (ids.isEmpty) return;
    final sorted = ids.toList()..sort();
    final first = sorted.first;
    final last = sorted.last;
    final contextStart = (first - _contextParagraphs)
        .clamp(0, paragraphs.length)
        .toInt();
    final contextEnd = (last + 1).clamp(0, paragraphs.length - 1).toInt();
    final excerpt = StringBuffer();
    for (var i = contextStart; i <= contextEnd; i++) {
      excerpt.write('[$i] ${paragraphs[i]}\n\n');
    }
    final prompt =
        '''
You attribute quoted dialogue to characters in an English novel.
Known characters: ${known.isEmpty ? 'none yet' : known}
${lead == null || lead.isEmpty ? '' : 'Main character: $lead'}

The excerpt is numbered by paragraph. For every requested paragraph that
contains text inside quotation marks, identify who is speaking.
Use a known character name exactly. A two-person conversation can alternate
when a reply has no tag. A quoted paragraph with no new speaker keeps the
previous speaker. Do not include paragraphs without quotes. Do not invent
characters; use Unknown when there is no clue.

Requested paragraph numbers: ${sorted.join(', ')}

Excerpt:
$excerpt
Return only a JSON array with one object per requested dialogue paragraph:
[{"paragraph": 12, "speaker": "Elizabeth"}]
Do not explain your answer.
''';
    try {
      final raw = await Lfm3Model.generate(
        prompt,
        maxTokens: _maxOutputTokens,
        responseFormat: _format,
      );
      suggestions.addAll(_parse(raw, requestedIds: ids));
    } on Lfm3Exception catch (error) {
      if (sorted.length > 1 && error.message.contains('outputLimit')) {
        final middle = sorted.length ~/ 2;
        await _attribute(
          paragraphs: paragraphs,
          ids: sorted.sublist(0, middle).toSet(),
          known: known,
          lead: lead,
          suggestions: suggestions,
        );
        await _attribute(
          paragraphs: paragraphs,
          ids: sorted.sublist(middle).toSet(),
          known: known,
          lead: lead,
          suggestions: suggestions,
        );
        return;
      }
      rethrow;
    }
  }

  static Map<int, String> _parse(String raw, {required Set<int> requestedIds}) {
    var value = raw
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|endoftext|>', '')
        .trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(value);
    if (fence != null) value = fence.group(1)!.trim();
    final start = value.indexOf('[');
    final end = value.lastIndexOf(']');
    if (start < 0 || end <= start) {
      throw const Lfm3Exception('LFM3 did not return valid speaker JSON.');
    }
    final decoded = jsonDecode(value.substring(start, end + 1));
    if (decoded is! List) {
      throw const Lfm3Exception('LFM3 did not return a speaker list.');
    }
    final result = <int, String>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final rawParagraph = item['paragraph'];
      final paragraph = rawParagraph is num
          ? rawParagraph.toInt()
          : int.tryParse('$rawParagraph');
      final speaker = item['speaker']?.toString().trim();
      if (paragraph == null || speaker == null || speaker.isEmpty) continue;
      if (!requestedIds.contains(paragraph)) continue;
      result[paragraph] = _cleanSpeaker(speaker);
    }
    return result;
  }

  static String _cleanSpeaker(String value) {
    var name = value
        .replaceAll(RegExp(r"""^["“”']|["“”']$"""), '')
        .replaceAll(RegExp(r'[.,;:!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty) return 'Unknown';
    final lower = name.toLowerCase();
    if (lower == 'unknown' || lower == 'narrator' || lower == 'none') {
      return 'Unknown';
    }
    return name;
  }
}
