import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:photo_manager/photo_manager.dart';

import 'core/android_service.dart';
import 'core/ios_background.dart';
import 'core/sync_client.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initAndroidService();
  await initIosBackground();
  runApp(const PhotoBridgeApp());
}

class PhotoBridgeApp extends StatelessWidget {
  const PhotoBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D6B);
    return MaterialApp(
      title: 'PhotoBridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // Lets Android minimize instead of closing on back.
      home: const WithForegroundTask(child: _Bootstrap()),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<SyncClient> _client = _start();

  Future<SyncClient> _start() async {
    // Prompts need this (UI) isolate; the engine may live elsewhere.
    final photos = await PhotoManager.requestPermissionExtend();
    final client = await SyncClient.create();
    client.send('photoAccess', {'granted': photos.hasAccess});
    if (Platform.isAndroid &&
        !await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return client;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SyncClient>(
      future: _client,
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not start: ${snap.error}'),
              ),
            ),
          );
        }
        final c = snap.data;
        if (c == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return HomePage(client: c);
      },
    );
  }
}
