import 'package:kvantum_app/ai/llm_provider.dart';

import 'harness.dart';

/// Scripted stand-in for the model: each step answers one `generate` call.
class FakeLlm implements LLMProvider {
  FakeLlm(this.script);
  final List<Object Function(LlmRequest)>
  script; // LlmReply or an exception to throw
  final List<LlmRequest> requests = [];
  final List<String> models = [];

  /// How often the connection was closed (once per request in the app).
  int closed = 0;

  @override
  void close() => closed++;

  @override
  Future<LlmReply> generate(String model, LlmRequest request) async {
    requests.add(request);
    models.add(model);
    if (requests.length > script.length) {
      throw StateError('model called more often than scripted');
    }
    final r = script[requests.length - 1](request);
    if (r is LlmException) throw r;
    return r as LlmReply;
  }

  @override
  Future<List<LlmModel>> listModels() async => const [];
}

LlmReply calls(List<LlmToolCall> c, {String text = ''}) =>
    LlmReply(parts: [if (text.isNotEmpty) LlmText(text), ...c]);
LlmReply say(String t) => LlmReply(parts: [LlmText(t)]);
LlmToolCall tool(String name, [Map<String, Object?> args = const {}]) =>
    LlmToolCall(name, args);

Map<String, Object?> item(
  String title,
  String start,
  String end, {
  bool hard = false,
  String kind = 'workout',
}) => {
  'title': title,
  'start': start,
  'end': end,
  'tzid': bp,
  'kind': kind,
  'hard': hard,
  'reason': 'ok',
};

LlmToolCall propose(List<Map<String, Object?>> items) =>
    tool('propose_events', {'summary': 'Terv', 'proposals': items});

/// The tool results the service sent back in the latest request.
List<Map<String, Object?>> lastResults(FakeLlm llm) => [
  for (final p in llm.requests.last.turns.last.parts)
    if (p is LlmToolResult) p.result,
];
