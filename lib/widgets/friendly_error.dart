import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Turns a raw exception into one plain-language sentence for users.
/// The technical text stays available through [showFriendlyError].
String friendlyError(Object e) {
  final t = e.toString().toLowerCase();
  if (t.contains('socketexception') ||
      t.contains('failed host lookup') ||
      t.contains('network') ||
      t.contains('connection') ||
      t.contains('timed out') ||
      t.contains('timeout')) {
    return 'Please check your internet connection and try again.';
  }
  if (t.contains('429') || t.contains('too many') || t.contains('rate limit')) {
    return 'Too many requests right now. Wait a minute and try again.';
  }
  // Only a number in status position counts: "expected 512 bytes" used to be
  // read as a server outage.
  final code = int.tryParse(
      RegExp(r'(?:status|http|code|error)[^0-9]{0,6}(\d{3})').firstMatch(t)?.group(1) ?? '');
  if (code != null && code >= 500 && code <= 599) {
    return 'The music service is having problems. Try again later.';
  }
  return 'Something went wrong. Please try again.';
}

/// Styled error popup: a plain message on top, technical details collapsed.
Future<void> showFriendlyError(
  BuildContext context, {
  required String title,
  required Object error,
}) {
  final raw = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.error_outline, color: AppColors.danger, size: 32),
      title: Text(title, textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            friendlyError(error),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.inkSoft, fontSize: 15),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Technical details',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft)),
            children: [
              SelectableText(raw,
                  style: TextStyle(fontSize: 11, color: AppColors.inkSoft)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
