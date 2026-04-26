import 'package:flutter/material.dart';

import 'pages/scan_page.dart';

void main() => runApp(const WrApp());

class WrApp extends StatelessWidget {
  const WrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'wearable-recorder',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ScanPage(),
    );
  }
}
