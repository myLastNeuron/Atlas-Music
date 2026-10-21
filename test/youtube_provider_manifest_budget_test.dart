import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:atlas_music/media/providers/youtube_provider.dart';

/// The UK stall burned the whole 30s on the first client. These pin the
/// per-client / total budget arithmetic of `attemptWithBudget` without a
/// network, so a regression cannot reintroduce "one stall eats everything".
void main() {
  const perClient = Duration(milliseconds: 30);
  const total = Duration(milliseconds: 90);
  // One const client, four slots: the callback distinguishes by call order.
  const client = YoutubeApiClient({
    'context': {
      'client': {'clientName': 'TEST', 'clientVersion': '1'},
    },
  }, '');
  const clients = [client, client, client, client];

  Future<T> run<T>(
      Future<T> Function(int index, Duration budget) attempt) {
    var index = 0;
    return YouTubeProvider.attemptWithBudget<T>(
      clients: clients,
      total: total,
      perClient: perClient,
      attempt: (_, budget) => attempt(index++, budget),
    );
  }

  test('falls through to the next client when one throws', () async {
    final tried = <int>[];
    final result = await run<String>((i, budget) async {
      tried.add(i);
      if (i == 0) throw StateError('stalled');
      return 'ok';
    });
    expect(result, 'ok');
    expect(tried, [0, 1]);
  });

  test('one hanging client costs the per-client budget, not the total',
      () async {
    final stopwatch = Stopwatch()..start();
    var firstBudget = Duration.zero;
    final result = await run<String>((i, budget) {
      if (i > 0) return Future.value('ok');
      firstBudget = budget;
      return Completer<String>().future.timeout(budget);
    });
    stopwatch.stop();
    expect(result, 'ok');
    expect(firstBudget, perClient);
    expect(stopwatch.elapsed, lessThan(total),
        reason: 'second client must get a turn inside the total budget');
  });

  test('all hanging clients give up at the total budget, not clients × budget',
      () async {
    final stopwatch = Stopwatch()..start();
    await expectLater(
      run<String>((i, budget) => Completer<String>().future.timeout(budget)),
      throwsA(anything),
    );
    stopwatch.stop();
    // Timer deadlines are computed from a clock that starts a fraction of a
    // millisecond after this stopwatch, so an exact comparison flakes.
    expect(stopwatch.elapsed,
        greaterThanOrEqualTo(total - const Duration(milliseconds: 5)));
    expect(stopwatch.elapsed, lessThan(total * 2),
        reason: 'budget must be shared across clients, not multiplied');
  });

  test('callbacks that throw are skipped like empty results', () async {
    final result = await run<String>((i, budget) async {
      if (i == 0) throw StateError('no audio streams');
      return 'ok';
    });
    expect(result, 'ok');
  });

  test('visitorData is injected without mutating the shared const payload', () {
    final withToken = YouTubeProvider.withVisitorData(client, 'tok');
    expect(
      withToken.payload['context']['client']['visitorData'],
      'tok',
    );
    expect(
      client.payload['context']['client'].containsKey('visitorData'),
      isFalse,
      reason: 'const payloads are shared; the token is per app run',
    );
  });
}
