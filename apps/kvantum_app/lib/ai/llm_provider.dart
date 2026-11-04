/// Provider-neutral model of one conversation with a tool-calling LLM.
sealed class LlmPart {
  const LlmPart();
}

class LlmText extends LlmPart {
  const LlmText(this.text);
  final String text;
}

class LlmToolCall extends LlmPart {
  const LlmToolCall(this.name, this.args, {this.raw, this.id});
  final String name;

  /// Provider-assigned call id (OpenAI-style APIs need it to match results).
  final String? id;
  final Map<String, Object?> args;

  /// The provider's own representation of this part. It is sent back
  /// unchanged on the next turn (some models require opaque fields such as
  /// thought signatures to be echoed).
  final Map<String, Object?>? raw;
}

class LlmToolResult extends LlmPart {
  const LlmToolResult(this.name, this.result, {this.id});
  final String name;

  /// The id of the call this answers (see [LlmToolCall.id]).
  final String? id;
  final Map<String, Object?> result;
}

class LlmTurn {
  const LlmTurn(this.role, this.parts);

  /// 'user' (also carries tool results) or 'model'.
  final String role;
  final List<LlmPart> parts;
}

class ToolDecl {
  const ToolDecl(this.name, this.description, this.parameters);
  final String name;
  final String description;

  /// JSON-schema style object description of the arguments.
  final Map<String, Object?> parameters;
}

class LlmRequest {
  const LlmRequest({
    required this.system,
    required this.turns,
    this.tools = const [],
    this.temperature = 0.4,
  });
  final String system;
  final List<LlmTurn> turns;
  final List<ToolDecl> tools;
  final double temperature;
}

class LlmReply {
  const LlmReply({
    required this.parts,
    this.promptTokens,
    this.outputTokens,
    this.finishReason,
  });
  final List<LlmPart> parts;
  final int? promptTokens;
  final int? outputTokens;
  final String? finishReason;

  String get text =>
      parts.whereType<LlmText>().map((p) => p.text).join('\n').trim();
  List<LlmToolCall> get toolCalls => parts.whereType<LlmToolCall>().toList();
}

class LlmModel {
  const LlmModel(this.id, this.displayName);
  final String id; // e.g. gemini-2.5-flash (without the "models/" prefix)
  final String displayName;
}

abstract class LLMProvider {
  Future<LlmReply> generate(String model, LlmRequest request);

  /// Models that can generate content with this key (also validates the key).
  Future<List<LlmModel>> listModels();
}

// ------------------------------------------------------------------ errors

sealed class LlmException implements Exception {
  const LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wrong, revoked or unauthorised key.
class LlmAuth extends LlmException {
  const LlmAuth(super.message);
}

/// Limit reached; [retryAfter] is the server's hint when it gave one.
class LlmRateLimit extends LlmException {
  const LlmRateLimit(
    super.message, {
    this.retryAfter,
    this.detail = '',
    this.quotaZero = false,
    this.daily = false,
    this.billing = false,
    this.model,
  });
  final Duration? retryAfter;

  /// The service's own explanation (never contains the key), for diagnosis.
  final String detail;

  /// The model has NO free quota for this key/account ("limit: 0"): waiting
  /// does not help, another model might.
  final bool quotaZero;

  /// The daily quota is used up: waiting minutes does not help either.
  final bool daily;

  /// Nothing to do with request rate: the account has no (or used up its)
  /// prepaid credit / billing. Waiting or switching models does not help.
  final bool billing;
  final String? model;

  /// A per-minute style limit that clears by itself shortly.
  bool get transient => !quotaZero && !daily && !billing;
}

/// No connection, timeout or a server-side problem; worth retrying later.
class LlmNetwork extends LlmException {
  const LlmNetwork(super.message);
}

/// The reply was empty, blocked or not understandable.
class LlmBadResponse extends LlmException {
  const LlmBadResponse(super.message);
}
