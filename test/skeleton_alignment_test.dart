import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:atlas_music/widgets/skeleton_card.dart';

void main() {
  testWidgets('skeleton rows match the real tile height', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(),
      home: Scaffold(
        body: ListView(children: [
          ListTile(
            key: const Key('tile'),
            leading: const SizedBox(width: 48, height: 48),
            title: const Text('Song title', style: TextStyle(fontSize: 14)),
            subtitle: Text('Artist',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft)),
            trailing: const SizedBox(width: 40, height: 12),
          ),
          const SkeletonListItem(key: Key('skeleton')),
        ]),
      ),
    ));
    expect(
      tester.getSize(find.byKey(const Key('skeleton'))).height,
      tester.getSize(find.byKey(const Key('tile'))).height,
    );
  });
}
