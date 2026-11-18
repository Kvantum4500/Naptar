import 'package:kvantum_core/kvantum_core.dart';

import '../llm_provider.dart';

/// One existing event the assistant suggests deleting. Nothing happens until
/// the user presses "Engedélyezem".
class DeletionProposal {
  const DeletionProposal(this.occurrence, this.reason);
  final Occurrence occurrence;
  final String reason;
}

/// One existing occurrence the assistant suggests moving. Nothing happens
/// until the user presses "Engedélyezem".
class MoveProposal {
  const MoveProposal(this.occurrence, this.newStart, this.newEnd, this.reason);
  final Occurrence occurrence;

  /// New local wall-clock times (in the occurrence's zone).
  final DateTime newStart;
  final DateTime newEnd;
  final String reason;
}

/// What the assistant came back with.
class AssistantOutcome {
  const AssistantOutcome({
    this.text = '',
    this.summary = '',
    this.items = const [],
    this.dropped = const [],
    this.questions = const [],
    this.deletions = const [],
    this.moves = const [],
    this.calls = 0,
    this.notice,
    this.usage,
    this.estimatedTokens,
    this.localAnswer,
  });

  /// Set when the program answered by itself, without a model (the budget, the
  /// agenda, or "that source is switched off"): [text] is that answer.
  final LocalAnswer? localAnswer;

  /// Plain answer (e.g. a question) when no plan was proposed.
  final String text;
  final String summary;

  /// Proposals that passed every rule; only these can be accepted.
  final List<ProposalItem> items;

  /// Why parts of the answer were not offered (parse problems, rule violations).
  final List<String> dropped;
  final List<String> questions;

  /// Existing events proposed for deletion (need explicit confirmation).
  final List<DeletionProposal> deletions;

  /// Existing events proposed for moving (need explicit confirmation).
  final List<MoveProposal> moves;

  /// Model calls it took.
  final int calls;

  /// Something worth telling about how this answer came about (e.g. it was
  /// made from less data after the first try failed).
  final String? notice;

  /// What the model calls cost, as the service reported (null: it did not).
  final LlmUsage? usage;

  /// The program's own estimate of the first request (3 characters = 1 token).
  final int? estimatedTokens;

  bool get hasPlan => items.isNotEmpty;

  AssistantOutcome _copy({
    String? notice,
    LlmUsage? usage,
    int? estimatedTokens,
    bool keepMoves = true,
    bool keepDeletions = true,
    bool keepItems = true,
  }) => AssistantOutcome(
    text: text,
    summary: summary,
    items: keepItems ? items : const [],
    dropped: dropped,
    questions: questions,
    deletions: keepDeletions ? deletions : const [],
    moves: keepMoves ? moves : const [],
    calls: calls,
    notice: notice ?? this.notice,
    usage: usage ?? this.usage,
    estimatedTokens: estimatedTokens ?? this.estimatedTokens,
    localAnswer: localAnswer,
  );

  AssistantOutcome withNotice(String n) =>
      _copy(notice: notice == null ? n : '$notice $n');

  /// The cost of the whole request, and what the first request was estimated at.
  AssistantOutcome withCost({LlmUsage? usage, int? estimatedTokens}) =>
      _copy(usage: usage, estimatedTokens: estimatedTokens);

  AssistantOutcome withoutMoves() => _copy(keepMoves: false);
  AssistantOutcome withoutDeletions() => _copy(keepDeletions: false);

  /// The answer after the new events were accepted or the plan was discarded:
  /// the cards that ask for a decision of their own (deletions, moves) stay.
  AssistantOutcome withoutItems() => _copy(keepItems: false);
}
