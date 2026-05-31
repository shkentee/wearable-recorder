import 'package:flutter/material.dart';

import 'pages/scan_page.dart';
import 'services/wr_foreground_service.dart';
import 'services/wr_opus_decoder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WrForegroundService.init();
  // Load libopus up-front so in-app playback has no first-tap stall. Best
  // effort — the Recordings page also calls ensureInit() lazily.
  try {
    await WrOpusDecoder.ensureInit();
  } catch (_) {
    // Opus unavailable (e.g. unsupported platform) — playback will surface it.
  }
  runApp(const WrApp());
}

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
