// Issue #230 B3 — a raw exception never reaches the Author.
//
// The New Route panel rendered this, verbatim, under START / END / VIA:
//
//   Routing unavailable — failed:ConnectionError: HTTPSConnectionPool(
//   host='overpass-api.de', port=443): Max retries exceeded with url:
//   /api/interpreter (Caused by NewConnectionError(...: Failed to establish
//   a new connection: [Errno 111] Connection refused))
//
// Flow 8 §01–02 specifies the opposite: fixed templates with typed slots and
// a short phrase table for causes — "nothing composes prose at runtime."
// `looksLikeRawDiagnostic` is the guard at the one boundary where the string
// does not originate in that table (a capability reason arriving over
// `/health`, or a client-side failure to reach it at all).

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/reason_phrase.dart';

void main() {
  group('looksLikeRawDiagnostic', () {
    test('catches the exact payload from the issue screenshot', () {
      const leak = "ConnectionError: HTTPSConnectionPool(host='overpass-api.de', "
          "port=443): Max retries exceeded with url: /api/interpreter (Caused by "
          "NewConnectionError(\"<urllib3.connection.HTTPSConnection object at "
          "0x7f>: Failed to establish a new connection: [Errno 111] Connection "
          "refused\"))";
      expect(looksLikeRawDiagnostic(leak), isTrue);
    });

    test('catches the shapes a diagnostic arrives in', () {
      for (final raw in [
        'Traceback (most recent call last):',
        'SocketException: Connection refused',
        'FormatException: Unexpected end of input',
        '[Errno 111] Connection refused',
        'GET https://overpass-api.de/api/interpreter failed',
        "host='overpass-api.de'",
        '#0      main (file:///x.dart:1:1)',
        '',
        '   ',
      ]) {
        expect(looksLikeRawDiagnostic(raw), isTrue, reason: raw);
      }
    });

    test('lets the sidecar\'s own finished sentences through untouched', () {
      for (final phrase in [
        "Couldn't reach the map-data service to prepare routing for this area.",
        'building the routing graph',
        'ensuring the routing region',
        'draw the trip area before routing is available',
        'the trip area could not be prepared for routing',
        'waiting on elevation',
      ]) {
        expect(looksLikeRawDiagnostic(phrase), isFalse, reason: phrase);
      }
    });
  });

  group('CapabilityStatus.describe', () {
    test('substitutes a fixed phrase for a leaked exception', () {
      const status = CapabilityStatus(
        ready: false,
        reason: "failed:ConnectionError: HTTPSConnectionPool(host='overpass-api.de', "
            "port=443): Max retries exceeded with url: /api/interpreter",
      );
      final line = status.describe('Routing');

      expect(line, 'Routing unavailable — something went wrong preparing it');
      // None of the payload survives to the panel.
      for (final fragment in [
        'ConnectionError',
        'overpass-api.de',
        '443',
        'HTTPSConnectionPool',
        'Errno',
        'failed:',
      ]) {
        expect(line.contains(fragment), isFalse, reason: fragment);
      }
    });

    test('still reads back a real, finished reason', () {
      const status = CapabilityStatus(
        ready: false,
        reason: "failed:Couldn't reach the map-data service to prepare routing "
            'for this area.',
      );
      expect(
        status.describe('Routing'),
        "Routing unavailable — Couldn't reach the map-data service to prepare "
        'routing for this area.',
      );
    });

    test('a still-warming capability is unaffected — it is not a failure', () {
      const status = CapabilityStatus(
        ready: false,
        reason: 'building graph',
        progress: 0.4,
        etaS: 180,
      );
      expect(status.failed, isFalse);
      expect(status.describe('Routing'), 'Routing loading — available in about 3 minutes');
    });
  });
}
