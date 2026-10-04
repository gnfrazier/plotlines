import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/health_poll_log.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('health_poll_log'));
  tearDown(() => tmp.deleteSync(recursive: true));

  List<Map<String, dynamic>> lines(String path) => File(path)
      .readAsLinesSync()
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();

  test('an unchanged body is not rewritten; the next line counts the repeats',
      () async {
    final path = '${tmp.path}/logs/health-poll.jsonl';
    final log = HealthPollLog(path);
    await log.append('{"ready": true}');
    for (var i = 0; i < 391; i++) {
      await log.append('{"ready": true}');
    }
    await log.append('{"ready": false}');
    final got = lines(path);
    expect(got, hasLength(2));
    expect(got[0].containsKey('unchanged_polls'), isFalse);
    expect(got[1]['unchanged_polls'], 391);
    expect(got[1]['body'], {'ready': false});
  });

  test('appending past the cap rolls the file over and keeps backupCount',
      () async {
    final path = '${tmp.path}/health-poll.jsonl';
    final log = HealthPollLog(path, maxBytes: 200, backupCount: 2);
    for (var i = 0; i < 40; i++) {
      await log.append('{"n": $i, "pad": "${'x' * 40}"}');
    }
    expect(File(path).lengthSync(), lessThan(200 + 120));
    expect(File('$path.1').existsSync(), isTrue);
    expect(File('$path.2').existsSync(), isTrue);
    expect(File('$path.3').existsSync(), isFalse);
    // Newest line is in the live file, and the rolled files are older.
    expect(lines(path).last['body']['n'], 39);
    expect(lines('$path.1').last['body']['n'],
        lessThan(lines(path).first['body']['n'] as int));
  });

  test('concurrent unawaited appends do not interleave or lose lines',
      () async {
    final path = '${tmp.path}/health-poll.jsonl';
    final log = HealthPollLog(path, maxBytes: 300, backupCount: 50);
    final pending = [
      for (var i = 0; i < 30; i++) log.append('{"n": $i}'),
    ];
    await Future.wait(pending);
    final all = <int>[];
    for (var k = 50; k >= 1; k--) {
      final f = File('$path.$k');
      if (f.existsSync()) all.addAll(lines(f.path).map((l) => l['body']['n'] as int));
    }
    all.addAll(lines(path).map((l) => l['body']['n'] as int));
    expect(all, List.generate(30, (i) => i));
  });
}
