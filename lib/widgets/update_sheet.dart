import 'package:flutter/material.dart';

import '../services/system_permissions.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import 'liquid_background.dart';

/// Checks GitHub for a newer release and, when one exists, offers to download
/// and install it. Styled like the app's other translucent-glass sheets.
Future<void> showUpdateSheet(BuildContext hostContext) {
  return showModalBottomSheet<void>(
    context: hostContext,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _UpdateSheet(),
  );
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet();

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  final _service = UpdateService();
  final _perms = SystemPermissions.instance;

  bool _checking = true;
  UpdateResult? _result;
  String? _error;
  double? _progress; // 0..1 while downloading
  bool _busy = false; // between "Update" tap and installer handoff

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final r = await _service.check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = r;
    });
  }

  Future<void> _startUpdate(AppRelease release) async {
    // Android 8.0+ needs a per-app "install unknown apps" allowance first.
    if (!await _perms.canInstallPackages()) {
      if (!mounted) return;
      final go = await _askToEnableInstalls();
      if (go != true || !mounted) return;
      await _perms.openInstallSettings();
      if (!mounted) return;
      setState(() => _error =
          'Allow installing from Atlas in the settings screen, then tap Update again.');
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await _service.downloadApk(
        release.apkUrl,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      final opened = await _perms.installApk(file.path);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        if (!opened) {
          _error = 'Could not open the installer. Download it from the release page instead.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = 'Download failed. Check your connection and try again.';
      });
    }
  }

  Future<bool?> _askToEnableInstalls() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('One quick setting'),
        content: const Text(
            'Android needs your permission before Atlas can install the '
            'update. Tap Continue, turn on "Allow from this source", then '
            'come back and tap Update again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      border: Border(top: BorderSide(color: AppColors.line)),
      shadow: false,
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, 24 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Check for updates',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          _body(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_checking) {
      return const _StatusRow(
        leading: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        text: 'Checking for updates…',
      );
    }

    final result = _result;
    if (result == null) {
      return _message(
        icon: Icons.wifi_off,
        text: 'Could not reach GitHub. Check your connection.',
        action: ('Try again', _check),
      );
    }

    if (!result.updateAvailable) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusRow(
            leading: Icon(Icons.check_circle,
                color: AppColors.ink, size: 20),
            text: "You're on the latest version (${result.installedVersion}).",
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    final latest = result.latest!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Version ${latest.version} is available',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          'You have ${result.installedVersion}.',
          style: TextStyle(fontSize: 12.5, color: AppColors.inkSoft),
        ),
        if (latest.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          // Plain text: release notes are markdown, but a renderer is not
          // worth a dependency for this.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.ink.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: SingleChildScrollView(
                child: Text(
                  latest.notes,
                  style: TextStyle(fontSize: 12.5, color: AppColors.inkSoft),
                ),
              ),
            ),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: _progress == null || _progress == 0 ? null : _progress,
          ),
          const SizedBox(height: 8),
          Text(
            _progress == null
                ? 'Preparing…'
                : 'Downloading update… ${(_progress! * 100).toStringAsFixed(0)}%',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppColors.inkSoft),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(fontSize: 12.5, color: AppColors.danger),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                // During a download this becomes Cancel: popping the sheet
                // disposes the service, which aborts the in-flight request.
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_busy ? 'Cancel' : 'Later'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _startUpdate(latest),
                child: Text(_busy ? 'Working…' : 'Update'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _message({
    required IconData icon,
    required String text,
    required (String, VoidCallback) action,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusRow(leading: Icon(icon, size: 20), text: text),
        const SizedBox(height: 16),
        FilledButton(onPressed: action.$2, child: Text(action.$1)),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  final Widget leading;
  final String text;

  const _StatusRow({required this.leading, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        leading,
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 14)),
        ),
      ],
    );
  }
}
