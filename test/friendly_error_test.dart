import 'package:atlas_music/widgets/friendly_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a plain number is not read as an HTTP status', () {
    // "expected 512 bytes" used to be reported as a server outage.
    expect(friendlyError(Exception('expected 512 bytes')),
        isNot(contains('music service is having problems')));
    expect(friendlyError(Exception('HTTP status 503')),
        contains('music service is having problems'));
  });

  test('rate limiting still reads as rate limiting', () {
    expect(friendlyError(Exception('HTTP status 429')),
        contains('Too many requests'));
    expect(friendlyError(Exception('too many requests')), contains('Too many'));
  });
}
