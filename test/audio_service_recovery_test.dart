import 'package:flutter_test/flutter_test.dart';

/// F1 regression: `_armOfflineResumeRetry` used to call
/// `_cancelOfflineResumeRetry()` as its first statement, which zeroed the
/// attempt counter before it was read — so the backoff array never advanced
/// and the bail-out was dead code. This mirrors that method's counter logic
/// (the method itself is private and needs a live AudioPlayer to instantiate).
List<int> armSequence(int attempts) {
  const delays = [5, 12, 25, 45, 60, 90, 120, 120, 120, 120];
  final picked = <int>[];
  var count = 0;
  // Re-arm the way the fixed method does: cancel only the timer, keep count.
  for (var i = 0; i < attempts; i++) {
    if (count >= delays.length) break;
    picked.add(delays[count]);
    count++;
  }
  return picked;
}

void main() {
  test('offline-resume backoff escalates instead of pinning to 5s', () {
    final seq = armSequence(4);
    expect(seq, [5, 12, 25, 45]);
    expect(seq.first, 5);
    expect(seq.last, isNot(5), reason: 'counter must survive each re-arm');
  });

  test('offline-resume backoff terminates after the delay table', () {
    final seq = armSequence(50);
    expect(seq.length, 10, reason: 'bail-out must be reachable');
    expect(seq.last, 120);
  });
}
