import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The time zone of the calendar that [Fake] answers the zone request with.
const fakeCalendarZone = 'Europe/Budapest';

/// A Google Calendar API stand-in: records every request and answers from
/// `handler`. The request for the calendar's own record (its time zone) is
/// answered here, the rest by `handler`.
class FakeGoogle {
  FakeGoogle(http.Response Function(http.Request r) handler) {
    client = MockClient((r) async {
      reqs.add(r);
      if (r.url.path.endsWith('/calendars/primary') && r.method == 'GET') {
        return jsonResp({'timeZone': fakeCalendarZone});
      }
      return handler(r);
    });
  }

  final List<http.Request> reqs = [];
  late final http.Client client;
}

/// A JSON answer, as the Google API gives it.
http.Response jsonResp(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// An error answer with the given HTTP status and Google error `reason`.
http.Response errResp(int status, [String reason = '']) => jsonResp({
  'error': {
    'code': status,
    'message': 'x',
    'errors': [
      {'reason': reason},
    ],
  },
}, status);
