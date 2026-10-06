import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'app_transitions.dart';

/// Floating frosted-glass tab bar. Translucent dark surface with blur so
/// content drifting behind stays subtly visible; the active tab is a single
/// soft white pill that glides between tabs, while icons/labels fade and
/// scale in place.
class FloatingGlassNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const FloatingGlassNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.home_outlined, Icons.home, 'Home'),
      (Icons.search_outlined, Icons.search, 'Search'),
      (Icons.library_music_outlined, Icons.library_music, 'Library'),
      (Icons.person_outline, Icons.person, 'Profile'),
    ];
    final bottom = MediaQuery.of(context).padding.bottom;
    final pillDuration = AppMotion.dur(context, AppMotion.modal);
    // Align places the child within (parent - child) space, so the pill
    // centre lands on slot i at 2*i/(n-1) - 1, not (2*i+1)/n.
    final pillAlign =
        Alignment(-1 + 2 * currentIndex / (items.length - 1), 0);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 12 + bottom * 0.4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AppColors.glassBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Single pill that glides to the active slot.
                Positioned.fill(
                  child: AnimatedAlign(
                    duration: pillDuration,
                    curve: AppMotion.emphasized,
                    alignment: pillAlign,
                    child: FractionallySizedBox(
                      widthFactor: 1 / items.length,
                      heightFactor: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: DecoratedBox(
                          key: const ValueKey('nav_pill'),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: Colors.white.withValues(alpha: 0.16),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.22)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: List.generate(items.length, (i) {
                    final active = i == currentIndex;
                    final data = items[i];
                    return Expanded(
                      child: MotionPress(
                        scale: 0.94,
                        child: GestureDetector(
                          key: ValueKey('nav_$i'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onTap(i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedScale(
                                  scale: active ? 1.08 : 1,
                                  duration:
                                      AppMotion.dur(context, AppMotion.micro),
                                  curve: Curves.easeOutBack,
                                  child: Icon(active ? data.$2 : data.$1,
                                      size: 22,
                                      color: active
                                          ? Colors.white
                                          : AppColors.mute),
                                ),
                                const SizedBox(height: 2),
                                AnimatedDefaultTextStyle(
                                  duration:
                                      AppMotion.dur(context, AppMotion.micro),
                                  curve: AppMotion.curve,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color:
                                        active ? Colors.white : AppColors.mute,
                                  ),
                                  child: Text(data.$3),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
