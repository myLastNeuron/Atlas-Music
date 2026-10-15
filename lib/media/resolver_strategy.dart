import 'dart:async';
import 'dart:io';
import 'dart:math';
import '../../models/song.dart';
import 'media_source.dart';
import 'media_resolver.dart';
import 'resolve_failure.dart';

/// Explicit provider chain: CACHE is checked by the caller, then providers
/// are tried strictly in order — P1 → P2 → … → FAIL. No recursion, no
/// re-entry: one pass, every attempt recorded in [PlaybackReport].
///
/// A failure never blocks a provider for the next song. Shared resolve-time
/// retries (below) absorb transient stalls, and every song starts a fresh
/// attempt through the full chain in order.
class ResolverStrategy {
  static const _validateBudget = Duration(seconds: 20);

  final List<MediaResolver> providers;

  ResolverStrategy(this.providers);

  /// Shared resolve→validate for one provider. On a url-scoped validation
  /// failure (expired/throttled URL), discards the URL, resolves fresh
  /// once, and retries validation once. Transport timeouts get one jittered
  /// retry: a single slow response is not a dead backend.
  Future<MediaSource?> _resolveValidated(
    MediaResolver p,
    Song song,
    PlaybackReport report,
  ) async {
    MediaSource candidate;
    try {
      candidate = await p.resolve(song).timeout(p.resolveBudget);
    } on ResolveFailure catch (e) {
      report.add(e);
      return null;
    } on TimeoutException catch (e) {
      // One retry after 0.5–1.5s jitter. Thundering-herd avoidance for
      // throttled networks; still bounded and fast.
      await Future.delayed(
          Duration(milliseconds: 500 + Random().nextInt(1000)));
      try {
        candidate = await p.resolve(song).timeout(p.resolveBudget);
        report.add(ResolveFailure(
          provider: p.provider,
          stage: ResolveStage.resolution,
          scope: FailureScope.provider,
          detail: 'first attempt timed out, retrying once',
          retryable: true,
        ));
      } on ResolveFailure catch (e2) {
        report.add(e2);
        return null;
      } on TimeoutException catch (e2) {
        report.add(ResolveFailure(
          provider: p.provider,
          stage: ResolveStage.resolution,
          scope: FailureScope.provider,
          detail: 'resolve exceeded ${p.resolveBudget.inSeconds}s twice: $e2',
          retryable: true,
        ));
        return null;
      } catch (e2) {
        report.add(ResolveFailure(
          provider: p.provider,
          stage: ResolveStage.resolution,
          scope: FailureScope.provider,
          detail: 'retry unexpected: $e2 (first: $e)',
          retryable: false,
        ));
        return null;
      }
    } catch (e) {
      report.add(ResolveFailure(
        provider: p.provider,
        stage: ResolveStage.resolution,
        scope: FailureScope.provider,
        detail: 'unexpected: $e',
        retryable: false,
      ));
      return null;
    }
    try {
      final valid = await p.validate(candidate).timeout(_validateBudget);
      return valid;
    } on ResolveFailure catch (e) {
      report.add(e);
      if (e.scope == FailureScope.url) {
        // One expired URL ≠ dead provider. Fresh resolve, one retry.
        try {
          final fresh = await p.resolve(song).timeout(p.resolveBudget);
          final valid = await p.validate(fresh).timeout(_validateBudget);
          return valid;
        } on ResolveFailure catch (e2) {
          report.add(e2);
        } catch (e2) {
          report.add(ResolveFailure(
            provider: p.provider,
            stage: ResolveStage.validation,
            scope: FailureScope.provider,
            detail: 'fresh-retry unexpected: $e2',
            retryable: false,
          ));
        }
        return null;
      }
      return null;
    } on TimeoutException catch (e) {
      report.add(ResolveFailure(
        provider: p.provider,
        stage: ResolveStage.validation,
        scope: FailureScope.provider,
        detail: 'validation exceeded 20s: $e',
        retryable: true,
      ));
      return null;
    } catch (e) {
      report.add(ResolveFailure(
        provider: p.provider,
        stage: ResolveStage.validation,
        scope: FailureScope.provider,
        detail: 'unexpected: $e',
        retryable: false,
      ));
      return null;
    }
  }

  /// First resolve()+validate() success in provider order, or null.
  /// Every failure lands in [report] with provider + stage + scope.
  Future<MediaSource?> resolveFirstValid(
      Song song, PlaybackReport report) async {
    for (final p in providers) {
      final got = await _resolveValidated(p, song, report);
      if (got != null) return got;
    }
    return null;
  }

  /// Resolve-then-download through the same provider order into [file].
  /// Returns the source that produced the file, or null (see [report]).
  Future<MediaSource?> downloadFirstValid(
    Song song,
    File file,
    PlaybackReport report, {
    Duration budget = const Duration(seconds: 150),
  }) async {
    for (final p in providers) {
      final candidate = await _resolveValidated(p, song, report);
      if (candidate == null) continue;
      try {
        await p.download(candidate, file).timeout(budget);
        if (await file.exists() && await file.length() > 0) {
          return candidate;
        }
        report.add(ResolveFailure(
          provider: p.provider,
          stage: ResolveStage.download,
          scope: FailureScope.url,
          detail: 'download produced empty file',
          retryable: true,
        ));
      } on ResolveFailure catch (e) {
        report.add(e);
      } catch (e) {
        report.add(ResolveFailure(
          provider: p.provider,
          stage: ResolveStage.download,
          scope: FailureScope.provider,
          detail: 'unexpected: $e',
          retryable: false,
        ));
      }
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    return null;
  }
}
