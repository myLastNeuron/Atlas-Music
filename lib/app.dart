import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'screens/welcome_flow.dart';

class AtlasMusicApp extends StatelessWidget {
  const AtlasMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Atlas Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const WelcomeScreen(),
    );
  }
}
