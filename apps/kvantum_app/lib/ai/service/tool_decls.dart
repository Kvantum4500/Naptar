import 'package:kvantum_core/kvantum_core.dart';

import '../llm_provider.dart';

// The tool declarations are sent with EVERY model call, so they are kept as
// short as the model can still use them (the long rules live once, in the
// system prompt). Which of them a request gets: [assistantToolsFor].
const _getEvents = ToolDecl(
  'get_events',
  'A naptár eseményei egy időszakban.',
  {
    'type': 'object',
    'properties': {
      'from': {'type': 'string', 'description': 'ÉÉÉÉ-HH-NN, alapból ma'},
      'to': {'type': 'string', 'description': 'Utolsó nap, alapból +14 nap'},
    },
  },
);
const _getFinance = ToolDecl(
  'get_finance',
  'Pénzügyi adat (Ft): havi összesítés, esedékes ismétlődők, célok, utolsó tételek; honap megadásával annak a hónapnak a tételei.',
  {
    'type': 'object',
    'properties': {
      'honap': {
        'type': 'string',
        'description': 'ÉÉÉÉ-HH, alapból ez és az előző',
      },
    },
  },
);
const _getCheckins = ToolDecl('get_checkins', 'Napi check-inek.', {
  'type': 'object',
  'properties': {
    'days': {
      'type': 'integer',
      'description': 'Hány nap vissza (1–30), alapból 7',
    },
  },
});
const _findFreeSlots = ToolDecl('find_free_slots', 'Szabad idősávok.', {
  'type': 'object',
  'properties': {
    'from': {'type': 'string', 'description': 'ÉÉÉÉ-HH-NN, alapból ma'},
    'to': {'type': 'string', 'description': 'Utolsó nap, alapból +7 nap'},
    'minutes': {
      'type': 'integer',
      'description': 'Legalább ennyi perc (15–480), alapból 60',
    },
  },
});
// How the proposal tool is used (when deleting / moving is allowed, what a
// reference is, which time format) is written once, in the system prompt.
const _proposalItem = {
  'type': 'object',
  'properties': {
    'title': {'type': 'string'},
    'start': {'type': 'string'},
    'end': {'type': 'string'},
    'kind': {
      'type': 'string',
      'enum': ['workout', 'task', 'rest', 'other'],
    },
    'hard': {'type': 'boolean'},
    'outdoor': {'type': 'boolean'},
    'taskId': {'type': 'string'},
    'reason': {'type': 'string', 'description': 'legfeljebb 12 szó'},
  },
  'required': ['title', 'start', 'end'],
};
const _deletionItem = {
  'type': 'object',
  'properties': {
    'ref': {'type': 'string'},
    'reason': {'type': 'string'},
  },
  'required': ['ref'],
};
const _moveItem = {
  'type': 'object',
  'properties': {
    'ref': {'type': 'string'},
    'start': {'type': 'string'},
    'end': {'type': 'string'},
    'reason': {'type': 'string'},
  },
  'required': ['ref', 'start', 'end'],
};
const _proposeDescription =
    'A végső terv leadása; semmi nem történik jóváhagyás nélkül.';

/// Planning: new events only. A plan request cannot delete or move anything,
/// so the tool does not even offer it (and the events carry no references).
const _proposePlan = ToolDecl('propose_events', _proposeDescription, {
  'type': 'object',
  'properties': {
    'summary': {'type': 'string'},
    'proposals': {'type': 'array', 'items': _proposalItem},
    'questions': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
});

/// Deleting / moving (and anything new that goes with it).
const _proposeEdit = ToolDecl('propose_events', _proposeDescription, {
  'type': 'object',
  'properties': {
    'summary': {'type': 'string'},
    'proposals': {'type': 'array', 'items': _proposalItem},
    'deletions': {'type': 'array', 'items': _deletionItem},
    'moves': {'type': 'array', 'items': _moveItem},
    'questions': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
});

/// The tools a request is offered, by what it is about: a deletion / move
/// needs only the events, a pure money question only the money data, a plan the
/// lot. Every tool left out is some hundred tokens saved on every model call.
List<ToolDecl> assistantToolsFor(AskScope scope) {
  // a move often means "to a free time": the free slots are one call away;
  // with planning in the same request the check-ins are one call away too
  if (scope.edit) {
    return [
      _getEvents,
      if (scope.mixed) _getCheckins,
      _findFreeSlots,
      _proposeEdit,
    ];
  }
  if (scope.finance && !scope.events) return const [_getFinance];
  // No get_tasks here: the first message already carries every open task, so
  // the tool could only repeat it.
  return [
    _getEvents,
    _getCheckins,
    _findFreeSlots,
    if (scope.finance) _getFinance,
    _proposePlan,
  ];
}
