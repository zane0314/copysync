import 'dart:io';

import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'state/app_state.dart';
import 'state/token_store.dart';
import 'ui/home_shell.dart';
import 'ui/login_page.dart';

void main() {
  // restoreSession 会走方法通道读 Keychain，必须先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();
  final baseUrl =
      Platform.isAndroid ? 'http://10.0.2.2:15101' : 'http://127.0.0.1:15101';
  final state = AppState(
    api: ApiClient(baseUrl),
    tokenStore: SecureTokenStore(),
  );
  state.restoreSession();
  runApp(CopySyncApp(state: state));
}

class CopySyncApp extends StatelessWidget {
  const CopySyncApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CopySync',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2B7DE9)),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) =>
            state.isLoggedIn ? HomeShell(state: state) : LoginPage(state: state),
      ),
    );
  }
}
