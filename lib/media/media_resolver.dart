import 'dart:io';
import '../models/song.dart';
import 'media_source.dart';
import 'resolve_failure.dart';

/// Contract every music backend implements. AudioService programs against
/// this interface only and never imports provider-specific packages.
///
/// Flow per provider: [resolve] → [validate] → hand to ExoPlayer, or
/// [download] for the offline path. All errors are [ResolveFailure]
/// (structured); anything else thrown is a bug.
abstract class MediaResolver {
  MediaProvider get provider;

  /// Wall-clock budget for [resolve]. Strategy enforces it.
  Duration get resolveBudget;

  /// Turn a [Song] into a candidate [MediaSource].
  /// Throws [ResolveFailure] with stage [ResolveStage.resolution].
  Future<MediaSource> resolve(Song song);

  /// Prove a candidate is actually playable: HTTP reachability,
  /// non-zero length, unexpired, compatible container.
  /// Returns the (possibly enriched) source or throws [ResolveFailure]
  /// with stage [ResolveStage.validation].
  Future<MediaSource> validate(MediaSource source);

  /// Fetch [source] to [file] for offline playback. Same abstraction as
  /// streaming: no duplicated provider logic in the caller.
  /// Throws [ResolveFailure] with stage [ResolveStage.download].
  Future<void> download(MediaSource source, File file);
}
