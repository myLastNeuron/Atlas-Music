import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shazam_identifier/shazam_identifier.dart';

import 'package:atlas_music/services/identify_flow.dart';

/// Stands in for the native recorder so the flow can be exercised without a
/// device. Counts create/dispose to prove every attempt releases its recorder.
class _FakePlatform extends RecordPlatform {
  int creates = 0;
  int disposes = 0;
  bool granted = true;
  bool failStart = true;

  @override
  Future<void> create(String recorderId) async => creates++;

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      granted;

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    if (failStart) throw Exception('no mic');
  }

  @override
  Future<String?> stop(String recorderId) async => null;

  @override
  Future<void> dispose(String recorderId) async => disposes++;

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repeated attempts never throw and always release the recorder', () async {
    final fake = _FakePlatform();
    RecordPlatform.instance = fake;

    for (var i = 0; i < 5; i++) {
      final status = await identifyRaw();
      expect(status.state, RecognitionStatusState.error);
    }

    // One recorder per attempt, and every one disposed: no leaked AudioRecord.
    expect(fake.creates, 5);
    expect(fake.disposes, 5);
  });

  test('a denied mic returns a permission error and never starts recording',
      () async {
    final fake = _FakePlatform()..granted = false;
    RecordPlatform.instance = fake;

    final status = await identifyRaw();

    expect(status.state, RecognitionStatusState.error);
    expect(status.message, contains('permission'));
    expect(fake.disposes, 1);
  });
}
