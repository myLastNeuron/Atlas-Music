import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/playlist_qr.dart';
import '../theme/app_theme.dart';
import '../widgets/liquid_background.dart';

/// Scans (or reads from a photo) the QR code of a playlist shared from
/// another Atlas Music install. Long playlists span several parts; the screen
/// keeps collecting until every part has been seen, in any order, then returns
/// the decoded payload to the caller.
class PlaylistQrImportScreen extends StatefulWidget {
  const PlaylistQrImportScreen({super.key});

  @override
  State<PlaylistQrImportScreen> createState() => _PlaylistQrImportScreenState();
}

class _PlaylistQrImportScreenState extends State<PlaylistQrImportScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final _assembler = PlaylistQrAssembler();

  bool _done = false;
  bool _torch = false;
  bool _readingImage = false;
  bool _cameraFailed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) setState(() => _torch = !_torch);
    } catch (_) {
      // Camera without a flash: nothing to toggle.
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || _readingImage) return;
    for (final barcode in capture.barcodes) {
      if (_feed(barcode.rawValue)) return;
    }
  }

  /// Feeds one scanned value into the assembler. Returns true when the whole
  /// playlist is ready (the screen then closes with the payload).
  bool _feed(String? raw) {
    if (raw == null || raw.isEmpty || _done) return false;
    final before = _assembler.received;
    try {
      if (_assembler.accept(raw)) {
        _finish();
        return true;
      }
    } on FormatException catch (e) {
      _toast(e.message);
      return false;
    }
    if (_assembler.received > before) _onPartCaptured();
    return false;
  }

  void _finish() {
    final payload = _assembler.payload;
    if (payload == null) return;
    // Reachable from async image analysis that can outlive the screen: popping
    // then would close the route underneath.
    if (!mounted || _done) return;
    _done = true;
    HapticFeedback.mediumImpact();
    Navigator.pop(context, payload);
  }

  void _onPartCaptured() {
    if (!mounted) return;
    setState(() {});
    HapticFeedback.selectionClick();
    if (_assembler.isMultiPart) {
      _toast('Part ${_assembler.received} of ${_assembler.total} captured');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  Future<void> _pickImage() async {
    if (_done || _readingImage) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    setState(() => _readingImage = true);
    try {
      // The camera may already be stopped (permission denied, no camera):
      // that must not block reading a saved photo.
      try {
        await _controller.stop();
      } catch (_) {}
      final capture = await _controller.analyzeImage(picked.path);
      if (!mounted || _done) return;
      final values = capture?.barcodes
              .map((b) => b.rawValue)
              .whereType<String>()
              .toList() ??
          const <String>[];
      if (values.isEmpty) {
        _toast('No QR code found in that image');
        return;
      }
      final before = _assembler.received;
      for (final value in values) {
        if (_feed(value)) return;
      }
      if (_assembler.isMultiPart) {
        final got = _assembler.received;
        _toast(got > before
            ? 'Found $got of ${_assembler.total} parts — scan the rest with the camera'
            : 'That image only shows a part you already scanned');
      } else {
        _toast('That image does not contain a playlist QR code');
      }
    } catch (_) {
      _toast('Couldn\'t read that image');
    } finally {
      if (mounted) {
        setState(() => _readingImage = false);
        if (!_done) {
          try {
            await _controller.start();
          } catch (_) {}
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              // Permission denied / no camera: keep the gallery route usable.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_cameraFailed) {
                  setState(() => _cameraFailed = true);
                }
              });
              return const ColoredBox(color: Colors.black);
            },
          ),
          // Dim everything except the middle band so the code stands out.
          IgnorePointer(
            child: Column(
              children: [
                Expanded(child: Container(color: Colors.black54)),
                SizedBox(
                  height: 300,
                  child: Row(
                    children: [
                      Expanded(child: Container(color: Colors.black54)),
                      AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.9),
                                width: 3),
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                      ),
                      Expanded(child: Container(color: Colors.black54)),
                    ],
                  ),
                ),
                Expanded(child: Container(color: Colors.black54)),
              ],
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(
                          _torch ? Icons.flash_on : Icons.flash_off,
                          color: Colors.white,
                        ),
                        tooltip: 'Flash',
                        onPressed: _toggleTorch,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                _bottomPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomPanel() {
    final progress = _assembler.received;
    final total = _assembler.total;
    final label = total > 1
        ? 'Part $progress of $total scanned'
        : _cameraFailed
            ? 'Camera unavailable'
            : 'Point the camera at the playlist QR code';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: GlassPanel(
        radius: 22,
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Import Atlas Music Playlist',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink)),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
            ),
            if (total > 1) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : progress / total,
                  minHeight: 5,
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Keep the code in view until every part is captured.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: AppColors.mute),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _readingImage ? null : _pickImage,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.ink,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: _readingImage
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.image_outlined, size: 19),
                label: Text(_readingImage ? 'Reading image…' : 'Choose QR image',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
