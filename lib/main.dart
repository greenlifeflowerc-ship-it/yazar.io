import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'game/skin_registry.dart';
import 'screens/main_menu_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Fire-and-forget: start decoding all skin assets so bots have skins ready
  // by the time the player enters a game.
  SkinRegistry.instance.ensureLoaded();

  runApp(const YazarApp());
}

class YazarApp extends StatelessWidget {
  const YazarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YAZAR.IO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const MainMenuScreen(),
    );
  }
}
