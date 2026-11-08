import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Three-stop slider for the appearance mode: Light, Grey, Dark+. A plain
/// [Slider] with divisions keeps drag, tap and screen-reader behaviour; only
/// the track and thumb are restyled.
class ModeSlider extends StatelessWidget {
  const ModeSlider({super.key, required this.mode, required this.onChanged});

  final AppPalette mode;
  final ValueChanged<AppPalette> onChanged;

  static const _labels = ['Light', 'Grey', 'Dark+'];
  static const _accent = Color(0xFF2D7CFF);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            activeTrackColor: _accent,
            inactiveTrackColor: AppColors.inkSoft.withValues(alpha: 0.28),
            thumbColor: Colors.white,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const _GlowThumbShape(),
          ),
          child: Slider(
            value: mode.index.toDouble(),
            min: 0,
            max: 2,
            divisions: 2,
            onChanged: (v) => onChanged(AppPalette.values[v.round()]),
          ),
        ),
        Row(
          children: [
            for (var i = 0; i < _labels.length; i++)
              Expanded(
                child: Align(
                  alignment: switch (i) {
                    0 => Alignment.centerLeft,
                    2 => Alignment.centerRight,
                    _ => Alignment.center,
                  },
                  child: Text(
                    _labels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          mode.index == i ? FontWeight.w700 : FontWeight.w500,
                      color: mode.index == i ? AppColors.ink : AppColors.mute,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// White core with a blue halo, like the reference: the glow is a blurred
/// circle painted under the thumb, not a box shadow around the whole slider.
class _GlowThumbShape extends SliderComponentShape {
  const _GlowThumbShape();

  static const double _radius = 13;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_radius + 8);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(
      center,
      _radius + 8,
      Paint()
        ..color = ModeSlider._accent.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawCircle(center, _radius, Paint()..color = Colors.white);
  }
}
