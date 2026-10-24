import 'dart:async';
import 'dart:io';

// The `shazam_identifier` package only exports its high-level service, which
// hides the recorder and cannot be disposed deterministically. We drive the
// capture ourselves and reuse the package's pure, stateless helpers.
// ignore: implementation_imports
import 'package:shazam_identifier/src/audio_resampler.dart';
// ignore: implementation_imports
import 'package:shazam_identifier/src/shazam_client.dart';
// ignore: implementation_imports
import 'package:shazam_identifier/src/shazam_signature_generator.dart';
import 'package:record/record.dart';

import '../models/song.dart';
import 'youtube_service.dart';

/// Shared metadata facade — a fresh [YouTubeService] per identify leaks the
/// `http.Client` that YoutubeExplode opens and never closes.
final YouTubeService _youtube = YouTubeService();

/// Serializes listens so two taps never open two microphones at once.
Future<void> _queue = Future<void>.value();

/// Completes when the running capture is abandoned (sheet dismissed, Auto
/// listen stopped), so the capture ends now instead of holding the queue for
/// its full six seconds and blocking the next attempt.
Completer<void>? _cancelSignal;

/// Abandons the running capture, if any. The queued next attempt then starts
/// immediately instead of waiting behind a listen nobody is watching.
void cancelIdentify() {
  final signal = _cancelSignal;
  _cancelSignal = null;
  if (signal != null && !signal.isCompleted) signal.complete();
}

/// Input sample rate. Resampled to 16 kHz (what Shazam expects) after capture.
const int _sampleRate = 44100;

/// Roughly as long as Shazam listens.
const Duration _listenDuration = Duration(seconds: 6);

/// Listens for ~6s and asks Shazam what it is. Never throws; every failure
/// comes back as an error or no-match [RecognitionStatus] the UI can show.
///
/// Runs while the app is visible: Android only grants the microphone to a
/// foreground app (there is no "always allow" for the mic), so callers must
/// have shown the Find-song UI before calling this.
///
/// A fresh [AudioRecorder] per attempt keeps the microphone lifecycle fully
/// deterministic: it is disposed (awaited) when the attempt ends, so a wedged
/// session can never poison the next one.
Future<RecognitionStatus> identifyRaw({bool ensurePermission = true}) {
  final run = _queue
      .then((_) => _recognizeOnce(ensurePermission: ensurePermission));
  _queue = run.then((_) {}, onError: (_) {});
  return run;
}

Future<RecognitionStatus> _recognizeOnce({required bool ensurePermission}) async {
  final recorder = AudioRecorder();
  Completer<void>? signal;
  try {
    if (ensurePermission) {
      final granted = await recorder.hasPermission();
      if (!granted) {
        return RecognitionStatus.error('Microphone permission not granted');
      }
    }

    final path = '${Directory.systemTemp.path}/atlas_identify_'
        '${DateTime.now().millisecondsSinceEpoch}.raw';
    try {
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
          // Never grab audio focus: taking it pauses our own playback (and
          // other players), leaving the mic listening to silence.
          audioInterruption: AudioInterruptionMode.none,
        ),
        path: path,
      );
    } catch (e) {
      return RecognitionStatus.error('Could not start the microphone: $e');
    }

    signal = _cancelSignal = Completer<void>();
    await Future.any<void>([
      Future<void>.delayed(_listenDuration),
      signal.future,
    ]);
    if (signal.isCompleted) {
      // Abandoned while capturing: drop the clip, don't ask Shazam.
      return RecognitionStatus.error('Cancelled');
    }
    final stopped = await recorder.stop();

    final file = File(stopped ?? path);
    final raw = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {
      // Best-effort cleanup; a leftover temp file is harmless.
    }
    if (raw.isEmpty) {
      return RecognitionStatus.error('No audio was captured');
    }

    final resampled = AudioResampler.resample(
      DecodedAudio(data: raw, channelCount: 1, sampleRate: _sampleRate),
      VibraSignature.requiredSampleRate,
    );
    final signature = VibraSignature.fromI16(resampled.data);
    final sampleMs =
        (resampled.data.length ~/ 2) * 1000 ~/ VibraSignature.requiredSampleRate;

    try {
      final result = await ShazamClient.recognize(signature, sampleMs)
          .timeout(const Duration(seconds: 20));
      return RecognitionStatus.success(result);
    } on TimeoutException {
      return RecognitionStatus.error('Recognition timed out. Try again.');
    } catch (e) {
      final message = e.toString();
      if (message.contains('No match') || message.contains('No matches')) {
        return RecognitionStatus.noMatch('No match found. Try again.');
      }
      return RecognitionStatus.error('Could not identify: $message');
    }
  } catch (e) {
    return RecognitionStatus.error('Could not listen: $e');
  } finally {
    if (identical(_cancelSignal, signal)) _cancelSignal = null;
    try {
      await recorder.dispose();
    } catch (_) {
      // The recorder may already be gone; nothing to clean up.
    }
  }
}

/// Turns a recognized title/artist into something this app can play, reusing
/// the same YouTube search every other screen uses. Null = nothing playable.
Future<Song?> resolveSong(RecognitionResult result) async {
  final results =
      await _youtube.search('${result.title} ${result.artist}', limit: 5);
  return results.isNotEmpty ? results.first : null;
}

/// True when the microphone is granted, requesting it if needed. Used before a
/// long-running (Auto) listen can start.
Future<bool> ensureMicPermission() async {
  final recorder = AudioRecorder();
  try {
    return await recorder.hasPermission();
  } catch (_) {
    return false;
  } finally {
    try {
      await recorder.dispose();
    } catch (_) {
      // Nothing to release.
    }
  }
}
