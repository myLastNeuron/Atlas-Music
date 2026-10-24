import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Marks the row the user pinned with "Play next" in a song's menu. The pinned
/// song plays before the queue continues; the list keeps its order behind it.
class PlayNextBadge extends StatelessWidget {
  const PlayNextBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'PLAY NEXT',
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.ink,
        ),
      ),
    );
  }
}
