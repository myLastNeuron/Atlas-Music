import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/artwork_color.dart';
import '../services/audio_service.dart';
import '../services/glass_settings.dart';
import '../services/theme_settings.dart';
import '../theme/app_theme.dart';
import 'liquid_background.dart';

/// Opens the sleep timer picker. While it is open it follows the current
/// song's artwork colour itself (only when Artwork colour is enabled), so a
/// track change retints the sheet like the full player.
Future<void> showSleepTimerSheet(
        BuildContext context, AudioPlayerService audio) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SleepTimerSheet(audio: audio),
    );

/// The picker: an analog clock showing the expected stop time, preset
/// durations, a custom duration field and one start button.
class _SleepTimerSheet extends StatefulWidget {
  const _SleepTimerSheet({required this.audio});

  final AudioPlayerService audio;

  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> {
  static const int _defaultMinutes = 30;

  late int _minutes;
  late DateTime _end;
  bool _custom = false;
  String? _customError;
  final TextEditingController _customController = TextEditingController();

  ThemeSettings? _theme;
  Color? _accent;
  String? _accentSongId;
  String? _accentPath;
  int _accentRequest = 0;

  @override
  void initState() {
    super.initState();
    final deadline = widget.audio.sleepDeadline;
    final remaining = deadline?.difference(DateTime.now());
    if (remaining != null && remaining.inSeconds > 0) {
      // Reopening an active timer: show the real deadline, not a fresh one.
      _minutes = (remaining.inSeconds / 60).ceil();
      _end = deadline!;
    } else {
      _minutes = widget.audio.sleepDuration?.inMinutes ?? _defaultMinutes;
      _end = DateTime.now().add(Duration(minutes: _minutes));
    }
    _theme = context.read<ThemeSettings>();
    _theme!.addListener(_onTheme);
    widget.audio.addListener(_onAudio);
    // Seed from the cache synchronously so an already-read cover tints the
    // first frame; a fresh read starts after the first frame.
    final song = widget.audio.currentSong;
    if (song != null && _theme!.artworkColor) {
      final path = widget.audio.highResArtPathFor(song);
      final cached = cachedArtworkColor(song.thumbnailUrl, filePath: path);
      if (cached != null) {
        _accent = cached;
        _accentSongId = song.id;
        _accentPath = path;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncAccent();
    });
  }

  @override
  void dispose() {
    _theme?.removeListener(_onTheme);
    widget.audio.removeListener(_onAudio);
    _customController.dispose();
    super.dispose();
  }

  void _onTheme() {
    if (!mounted) return;
    if (!(_theme?.artworkColor ?? false)) {
      _clearAccent();
      return;
    }
    // Re-read even for the same song: the setting was off when it was last
    // resolved.
    _accentSongId = null;
    _accentPath = null;
    _syncAccent();
  }

  void _onAudio() {
    if (mounted) _syncAccent();
  }

  void _clearAccent() {
    if (_accent == null && _accentSongId == null) return;
    setState(() {
      _accent = null;
      _accentSongId = null;
      _accentPath = null;
    });
  }

  /// Reads the current song's tint, once per song/file. A track change while
  /// the sheet is open retints it, matching the full player.
  void _syncAccent() {
    final theme = _theme;
    if (theme == null || !theme.artworkColor) {
      _clearAccent();
      return;
    }
    final song = widget.audio.currentSong;
    if (song == null) {
      _clearAccent();
      return;
    }
    final path = widget.audio.highResArtPathFor(song);
    if (song.id == _accentSongId && path == _accentPath) return;
    _accentSongId = song.id;
    _accentPath = path;
    final cached = cachedArtworkColor(song.thumbnailUrl, filePath: path);
    if (cached != null) {
      if (cached != _accent) setState(() => _accent = cached);
      return;
    }
    final request = ++_accentRequest;
    dominantArtworkColor(song.thumbnailUrl, filePath: path).then((color) {
      if (!mounted || request != _accentRequest) return;
      if (widget.audio.currentSong?.id != song.id) return;
      if (!(_theme?.artworkColor ?? false)) return;
      setState(() => _accent = color);
    });
  }

  void _select(int minutes) {
    setState(() {
      _custom = false;
      _minutes = minutes;
      _end = DateTime.now().add(Duration(minutes: minutes));
    });
  }

  void _toggleCustom() {
    setState(() {
      _custom = !_custom;
      _customError = null;
      if (_custom) {
        _customController.text = '$_minutes';
        _customController.selection = TextSelection(
            baseOffset: 0, extentOffset: _customController.text.length);
      }
    });
  }

  void _onCustomChanged(String text) {
    final value = int.tryParse(text.trim());
    setState(() {
      _customError = null;
      if (value != null && value >= 1 && value <= 1440) {
        _minutes = value;
        _end = DateTime.now().add(Duration(minutes: value));
      }
    });
  }

  void _start() {
    var minutes = _minutes;
    if (_custom) {
      final value = int.tryParse(_customController.text.trim());
      if (value == null || value < 1 || value > 1440) {
        setState(() => _customError = 'Enter a number from 1 to 1440');
        return;
      }
      minutes = value;
    }
    widget.audio.setSleepTimer(Duration(minutes: minutes));
    Navigator.pop(context);
  }

  /// Ink that stays readable on a filled [color].
  static Color _onColor(Color color) =>
      color.computeLuminance() > 0.55 ? const Color(0xFF13131A) : Colors.white;

  @override
  Widget build(BuildContext context) {
    final clockSize = math.min(MediaQuery.sizeOf(context).width * 0.58, 220.0);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final accent = _accent;
    final highlight = accent ?? AppColors.ink;
    final startBackground = accent ?? AppColors.action;
    final startInk = accent == null ? AppColors.charcoal : _onColor(accent);
    // The accent wash scales with the glass setting, so the slider fades the
    // tint with the rest of the sheet instead of leaving a fixed overlay.
    final glass = glassLevel(context);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: math.max(
                240.0, MediaQuery.sizeOf(context).height * 0.94 - keyboard)),
        child: GlassSurface(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppColors.line)),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              gradient: accent == null
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        accent.withValues(alpha: 0.34 * glass),
                        accent.withValues(alpha: 0.10 * glass),
                      ],
                    ),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bedtime_outlined,
                            size: 22, color: highlight),
                        const SizedBox(width: 10),
                        Text(
                          'Sleep Timer',
                          style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ink),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close,
                              size: 22, color: AppColors.inkSoft),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: _ClockFace(
                          time: _end, size: clockSize, color: AppColors.ink),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 30, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.mist,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: '$_minutes',
                              style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.ink),
                            ),
                            TextSpan(
                              text: ' min',
                              style: TextStyle(
                                  fontSize: 15, color: AppColors.mute),
                            ),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.audio.sleepDeadline != null
                          ? 'Ends at ${TimeOfDay.fromDateTime(_end).format(context)}'
                          : 'New timer ends at '
                              '${TimeOfDay.fromDateTime(_end).format(context)}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: AppColors.mute),
                    ),
                    if (widget.audio.sleepActive)
                      Center(
                        child: TextButton(
                          onPressed: () {
                            widget.audio.cancelSleepTimer();
                            Navigator.pop(context);
                          },
                          child: Text(
                            'Turn off sleep timer',
                            style:
                                TextStyle(fontSize: 12, color: AppColors.mute),
                          ),
                        ),
                      ),
                    const SizedBox(height: 18),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 3.4,
                      children: [
                        for (final minutes
                            in AudioPlayerService.sleepOptionsMinutes)
                          _preset(minutes),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _customRow(),
                    if (_custom) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _customController,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4),
                        ],
                        style: TextStyle(fontSize: 16, color: AppColors.ink),
                        decoration: InputDecoration(
                          labelText: 'Custom duration',
                          suffixText: 'min',
                          helperText: '1–1440 minutes',
                          errorText: _customError,
                          labelStyle: TextStyle(color: AppColors.mute),
                          helperStyle: TextStyle(color: AppColors.mute),
                          filled: true,
                          fillColor: AppColors.mist,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide:
                                BorderSide(color: highlight, width: 1.2),
                          ),
                        ),
                        onChanged: _onCustomChanged,
                        onSubmitted: (_) => _start(),
                      ),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.play_arrow_rounded, size: 22),
                        label: const Text('Start Timer'),
                        style: FilledButton.styleFrom(
                          backgroundColor: startBackground,
                          foregroundColor: startInk,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999)),
                          textStyle: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preset(int minutes) {
    final selected = !_custom && _minutes == minutes;
    final highlight = _accent ?? AppColors.ink;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _select(minutes),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.mist,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? highlight : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.schedule,
                size: 17, color: selected ? highlight : AppColors.inkSoft),
            const SizedBox(width: 8),
            Text(
              '$minutes min',
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? AppColors.ink : AppColors.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customRow() {
    final highlight = _accent ?? AppColors.ink;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _toggleCustom,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.mist,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _custom ? highlight : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.edit_outlined,
                size: 18, color: _custom ? highlight : AppColors.inkSoft),
            const SizedBox(width: 10),
            Text(
              'Custom Duration',
              style: TextStyle(
                fontSize: 13,
                fontWeight: _custom ? FontWeight.w600 : FontWeight.w500,
                color: _custom ? AppColors.ink : AppColors.inkSoft,
              ),
            ),
            const Spacer(),
            Icon(
              _custom ? Icons.expand_less : Icons.chevron_right,
              size: 20,
              color: AppColors.inkSoft,
            ),
          ],
        ),
      ),
    );
  }
}

/// Analog face whose hands point at the time the timer will end.
class _ClockFace extends StatelessWidget {
  const _ClockFace({
    required this.time,
    required this.size,
    required this.color,
  });

  final DateTime time;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ClockPainter(time, color)),
      );
}

class _ClockPainter extends CustomPainter {
  _ClockPainter(this.time, this.color);

  final DateTime time;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: 0.45),
    );

    for (var hour = 0; hour < 12; hour++) {
      final angle = hour * math.pi / 6 - math.pi / 2;
      final quarter = hour % 3 == 0;
      final inner = radius * (quarter ? 0.80 : 0.88);
      final outer = radius * 0.96;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        Paint()
          ..strokeWidth = quarter ? 2.4 : 1.4
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: quarter ? 0.95 : 0.5),
      );
    }

    final hourAngle =
        ((time.hour % 12) + time.minute / 60) * math.pi / 6 - math.pi / 2;
    final minuteAngle = time.minute * math.pi / 30 - math.pi / 2;
    final hand = Paint()
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(
      center,
      center +
          Offset(math.cos(hourAngle) * radius * 0.32,
              math.sin(hourAngle) * radius * 0.32),
      hand..strokeWidth = 4,
    );
    canvas.drawLine(
      center,
      center +
          Offset(math.cos(minuteAngle) * radius * 0.46,
              math.sin(minuteAngle) * radius * 0.46),
      hand..strokeWidth = 3,
    );
    canvas.drawCircle(center, 4.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ClockPainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.color != color;
}
