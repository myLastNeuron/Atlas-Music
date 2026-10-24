import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';

/// The dominant colour of a song's artwork, or null when it cannot be read
/// (no artwork, offline, a corrupt file).
///
/// Used by the full player when "Artwork colour" is on. It resolves the same
/// image the artwork widget already cached — one download, and only a ~48 px
/// decode because the provider is wrapped in [ResizeImage] — so it never pulls
/// a second copy of the cover.
Future<Color?> dominantArtworkColor(String url, {String? filePath}) async {
  final provider = _providerFor(url, filePath);
  if (provider == null) return null;
  try {
    final image = await _resolve(provider);
    if (image == null) return null;
    // The image belongs to the image cache, so it is read, never disposed.
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return dominantColorOfPixels(data.buffer.asUint8List());
  } catch (_) {
    // Artwork colour is decoration: any failure just leaves the app palette.
    return null;
  }
}

/// Decode size for the sample: big enough to keep a colour region's shape,
/// small enough that reading every pixel costs nothing.
const int _sample = 48;

ImageProvider? _providerFor(String url, String? filePath) {
  final local = filePath;
  if (local != null && local.isNotEmpty) {
    return ResizeImage(FileImage(File(local)), width: _sample);
  }
  if (url.isEmpty) return null;
  if (url.startsWith('http')) {
    return ResizeImage(CachedNetworkImageProvider(url), width: _sample);
  }
  final file = File(url);
  if (!file.existsSync()) return null;
  return ResizeImage(FileImage(file), width: _sample);
}

Future<ui.Image?> _resolve(ImageProvider provider) {
  final completer = Completer<ui.Image?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  void finish(ui.Image? image) {
    if (!completer.isCompleted) completer.complete(image);
  }

  final listener = ImageStreamListener(
    (info, _) => finish(info.image),
    onError: (_, __) => finish(null),
  );
  stream.addListener(listener);
  return completer.future
      .whenComplete(() => stream.removeListener(listener));
}

/// The most prominent readable colour in [rgba] (unpremultiplied RGBA).
///
/// Pixels are bucketed at 32 levels per channel and the winning bucket is the
/// one that is both common and saturated, so a black border or a white margin
/// cannot outvote the artwork itself. A nearly monochrome cover falls back to
/// its average colour.
Color? dominantColorOfPixels(Uint8List rgba) {
  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  var totalR = 0, totalG = 0, totalB = 0, pixels = 0;

  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue; // transparent frame
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    totalR += r;
    totalG += g;
    totalB += b;
    pixels++;
    final key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3);
    counts[key] = (counts[key] ?? 0) + 1;
    final sum = sums.putIfAbsent(key, () => [0, 0, 0]);
    sum[0] += r;
    sum[1] += g;
    sum[2] += b;
  }
  if (pixels == 0) return null;

  int? best;
  var bestScore = 0.0;
  counts.forEach((key, count) {
    final sum = sums[key]!;
    final bucket = Color.fromARGB(
        255, sum[0] ~/ count, sum[1] ~/ count, sum[2] ~/ count);
    final hsv = HSVColor.fromColor(bucket);
    if (hsv.value < 0.10 || hsv.value > 0.92) return; // black / white
    final score = count * (0.15 + hsv.saturation);
    if (score > bestScore) {
      bestScore = score;
      best = key;
    }
  });

  if (best == null) {
    return Color.fromARGB(
        255, totalR ~/ pixels, totalG ~/ pixels, totalB ~/ pixels);
  }
  final sum = sums[best]!;
  final count = counts[best]!;
  return Color.fromARGB(
      255, sum[0] ~/ count, sum[1] ~/ count, sum[2] ~/ count);
}
