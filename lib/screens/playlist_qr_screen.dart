import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/playlist.dart';
import '../services/playlist_qr.dart';
import '../theme/app_theme.dart';
import '../widgets/liquid_background.dart';

/// Shows the QR code(s) that carry a playlist, and shares them as one image.
///
/// A single QR holds roughly 60 tracks; longer playlists are split into
/// numbered parts that cycle on screen so a phone camera can capture them all,
/// and the shared image contains every part stacked in one photo.
class PlaylistQrScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistQrScreen({super.key, required this.playlist});

  @override
  State<PlaylistQrScreen> createState() => _PlaylistQrScreenState();
}

class _PlaylistQrScreenState extends State<PlaylistQrScreen> {
  late final List<String> _parts;
  int _index = 0;
  bool _sharing = false;
  Timer? _cycle;

  bool get _multi => _parts.length > 1;

  @override
  void initState() {
    super.initState();
    _parts = PlaylistQrCodec.encode(widget.playlist);
    if (_multi) {
      _cycle = Timer.periodic(const Duration(milliseconds: 2400), (_) {
        if (!mounted || _sharing) return;
        setState(() => _index = (_index + 1) % _parts.length);
      });
    }
  }

  @override
  void dispose() {
    _cycle?.cancel();
    super.dispose();
  }

  void _step(int delta) {
    _cycle?.cancel();
    setState(() => _index = (_index + delta) % _parts.length);
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    try {
      final png = await renderQrShareCardPng(
        context,
        PlaylistQrShareCard(
          name: widget.playlist.name,
          songCount: widget.playlist.songs.length,
          parts: _parts,
        ),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${_fileName(widget.playlist.name)}');
      await file.writeAsBytes(png, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        fileNameOverrides: [_fileName(widget.playlist.name)],
        subject: 'Playlist "${widget.playlist.name}" on Atlas Music',
        text: 'Playlist "${widget.playlist.name}" '
            '(${widget.playlist.songs.length} songs). '
            'Open Atlas Music → Library → Import → '
            'Import Atlas Music Playlist, then scan this code to clone it.',
        sharePositionOrigin: origin,
      ));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t share the QR code')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Safe, human-readable file name for the shared image.
  static String _fileName(String name) {
    final clean = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final base = clean.isEmpty ? 'playlist' : clean;
    return 'atlas_playlist_${base.length > 40 ? base.substring(0, 40) : base}.png';
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.playlist.songs.length;
    return LiquidBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: AppColors.ink),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text('Share Playlist',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: AppColors.ink)),
          centerTitle: true,
        ),
        body: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.playlist.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  songs == 1 ? '1 song · Atlas Music playlist' : '$songs songs · Atlas Music playlist',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 13, color: AppColors.inkSoft),
                ),
                const SizedBox(height: 20),
                _QrCard(data: _parts[_index]),
                if (_multi) ...[
                  const SizedBox(height: 14),
                  _Pager(
                    index: _index,
                    total: _parts.length,
                    onStep: _step,
                  ),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _sharing ? null : _share,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.action,
                    foregroundColor: AppColors.charcoal,
                    disabledBackgroundColor:
                        AppColors.action.withValues(alpha: 0.5),
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                  ),
                  icon: _sharing
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.charcoal))
                      : const Icon(Icons.share, size: 20),
                  label: Text(
                    _sharing ? 'Preparing…' : 'Share QR Code',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 18),
                GlassPanel(
                  radius: 16,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.qr_code_scanner,
                          size: 18, color: AppColors.mute),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _multi
                              ? 'This playlist is too long for one QR code, so it '
                                  'uses ${_parts.length} parts. The image you share '
                                  'contains all of them; the app reads them in any order.'
                              : 'Anyone with Atlas Music can clone this playlist by '
                                  'scanning the code: Library → Import → Import '
                                  'Atlas Music Playlist.',
                          style: TextStyle(
                              fontSize: 12, height: 1.45,
                              color: AppColors.inkSoft),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// White QR surface. White is not a style choice: scanners need a light quiet
/// zone around dark modules, so the card stays white in the dark theme.
class _QrCard extends StatelessWidget {
  final String data;
  const _QrCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(builder: (context, constraints) {
        final side = constraints.maxWidth > 360 ? 340.0 : constraints.maxWidth;
        return RepaintBoundary(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: QrImageView(
              data: data,
              size: side,
              backgroundColor: Colors.white,
              padding: EdgeInsets.zero,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              semanticsLabel: 'Playlist QR code',
            ),
          ),
        );
      }),
    );
  }
}

class _Pager extends StatelessWidget {
  final int index;
  final int total;
  final void Function(int delta) onStep;

  const _Pager({required this.index, required this.total, required this.onStep});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: total > 1 ? () => onStep(-1) : null,
          icon: Icon(Icons.chevron_left, color: AppColors.inkSoft),
        ),
        Text('Part ${index + 1} of $total',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: AppColors.inkSoft)),
        IconButton(
          onPressed: total > 1 ? () => onStep(1) : null,
          icon: Icon(Icons.chevron_right, color: AppColors.inkSoft),
        ),
      ],
    );
  }
}

/// The image handed to WhatsApp / any other app: playlist name, song count and
/// every QR part on one white sheet.
class PlaylistQrShareCard extends StatelessWidget {
  final String name;
  final int songCount;
  final List<String> parts;

  const PlaylistQrShareCard({
    super.key,
    required this.name,
    required this.songCount,
    required this.parts,
  });

  static const double width = 560;

  /// Multi-code sheets get a wider canvas so each code keeps enough pixels per
  /// module after a messaging app re-encodes the picture.
  static const double multiWidth = 700;

  @override
  Widget build(BuildContext context) {
    final single = parts.length == 1;
    return Container(
      width: single ? width : multiWidth,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'ATLAS MUSIC',
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w700,
                color: Color(0xFF8A8A93)),
          ),
          const SizedBox(height: 10),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 24,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111114)),
          ),
          const SizedBox(height: 6),
          Text(
            songCount == 1 ? '1 song' : '$songCount songs',
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B6B73)),
          ),
          const SizedBox(height: 20),
          if (single)
            _QuietZone(
              child: QrImageView(
                data: parts.first,
                size: 430,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            )
          else
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 22,
              runSpacing: 18,
              children: [
                for (var i = 0; i < parts.length; i++)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _QuietZone(
                        child: QrImageView(
                          data: parts[i],
                          size: 268,
                          backgroundColor: Colors.white,
                          padding: EdgeInsets.zero,
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('Part ${i + 1} of ${parts.length}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF6B6B73))),
                    ],
                  ),
              ],
            ),
          const SizedBox(height: 20),
          const Text(
            'Library → Import → Import Atlas Music Playlist',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF6B6B73)),
          ),
        ],
      ),
    );
  }
}

/// White margin around a QR code. Scanners need a few modules of clear
/// background; without it, two codes side by side read as one unreadable
/// pattern.
class _QuietZone extends StatelessWidget {
  final Widget child;
  const _QuietZone({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

/// Paints [card] off-screen and returns it as PNG bytes. Uses an overlay entry
/// so the widget goes through a normal paint pass (no manual layout), and
/// removes it immediately after capturing.
Future<Uint8List> renderQrShareCardPng(BuildContext context, Widget card) async {
  final key = GlobalKey();
  final overlay = Overlay.of(context, rootOverlay: true);
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -4000,
      top: -4000,
      child: RepaintBoundary(
        key: key,
        child: Material(color: Colors.white, child: card),
      ),
    ),
  );
  overlay.insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('QR card was not laid out');
    final image = await boundary.toImage(pixelRatio: 2.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('QR card produced no image');
    return data.buffer.asUint8List();
  } finally {
    entry.remove();
  }
}
