import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';

import '../llm_provider.dart';

/// What goes to the model first. The real request and the preview are built by
/// the same code, so what the user can look at is what is sent.
class PreparedRequest {
  const PreparedRequest({
    required this.scope,
    required this.system,
    required this.tools,
    required this.firstMessage,
    this.reductions = const [],
  });
  final AskScope scope;
  final String system;
  final List<ToolDecl> tools;

  /// The data blocks, the time and the user's request.
  final String firstMessage;

  /// What was taken out to fit the provider's token budget, in this order.
  final List<String> reductions;

  int get systemTokens => estimateTokens(system.length);
  int get toolsTokens => estimateTokens(
    jsonEncode([
      for (final t in tools)
        {
          'name': t.name,
          'description': t.description,
          'parameters': t.parameters,
        },
    ]).length,
  );
  int get messageTokens => estimateTokens(firstMessage.length);

  /// The program's estimate of the whole first request.
  int get estimatedTokens => systemTokens + toolsTokens + messageTokens;

  /// The data blocks of the first message with their estimated sizes.
  List<({String name, int tokens})> get blocks => [
    for (final m in RegExp(
      r'<adat tipus="(\w+)">.*?</adat>',
      dotAll: true,
    ).allMatches(firstMessage))
      (name: m[1]!, tokens: estimateTokens(m[0]!.length)),
  ];

  PreparedRequest withReductions(List<String> r) => PreparedRequest(
    scope: scope,
    system: system,
    tools: tools,
    firstMessage: firstMessage,
    reductions: r,
  );
}

/// A rough size in tokens: 3 characters make one (Hungarian text is about
/// 3.0, JSON about 3.4; this errs on the big side on purpose).
int estimateTokens(int chars) => (chars / 3).ceil();
