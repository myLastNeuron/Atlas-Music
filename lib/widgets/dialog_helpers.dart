import 'dart:async';

import 'package:flutter/material.dart';

/// `showDialog`, but the dialog's text controllers are disposed only once the
/// route has finished animating out.
///
/// Disposing them when the future completes crashes the app: the pop returns
/// immediately, while the field still mounted for the exit transition keeps
/// using the controller (`framework.dart`: '_dependents.isEmpty' is not true).
Future<T?> showDisposingDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required List<ChangeNotifier> controllers,
}) async {
  try {
    return await showDialog<T>(context: context, builder: builder);
  } finally {
    // Longer than the dialog's exit transition (~150 ms stock, more with the
    // app's own motion scale).
    Timer(const Duration(milliseconds: 400), () {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
  }
}
