import 'package:flutter/material.dart';

import 'theme.dart' show contrastRatio;

/// Google Calendar's 11 event colours (colorId '1'..'11') with Hungarian names.
const eventColorNames = <String, String>{
  '1': 'Levendula',
  '2': 'Zsálya',
  '3': 'Szőlő',
  '4': 'Flamingó',
  '5': 'Banán',
  '6': 'Mandarin',
  '7': 'Páva',
  '8': 'Grafit',
  '9': 'Áfonya',
  '10': 'Bazsalikom',
  '11': 'Paradicsom',
};

const _eventColors = <String, Color>{
  '1': Color(0xFF7986CB),
  '2': Color(0xFF33B679),
  '3': Color(0xFF8E24AA),
  '4': Color(0xFFE67C73),
  '5': Color(0xFFF6BF26),
  '6': Color(0xFFF4511E),
  '7': Color(0xFF039BE5),
  '8': Color(0xFF616161),
  '9': Color(0xFF3F51B5),
  '10': Color(0xFF0B8043),
  '11': Color(0xFFD50000),
};

/// Colour of the app's own "Naptar" calendar (events without a colorId).
const defaultEventColor = Color(0xFF3F6FD8);

Color eventColor(String? colorId) => _eventColors[colorId] ?? defaultEventColor;

/// Readable text colour on top of [bg]: white or near-black, whichever stands
/// out more (a guess from the brightness alone left white on the mid-tones,
/// 2.8 : 1 on the flamingo colour).
Color onEventColor(Color bg) =>
    contrastRatio(Colors.white, bg) >= contrastRatio(Colors.black87, bg)
    ? Colors.white
    : Colors.black87;

List<MapEntry<String, Color>> get eventColorChoices =>
    _eventColors.entries.toList();
