import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// 登录页：服务器地址 + 密码 + 设备名称。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.state});

  final AppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _serverController;
  final _passwordController = TextEditingController();
  late final TextEditingController _deviceController;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: state.api.baseUrl);
    _deviceController = TextEditingController(
      text: Platform.isAndroid ? 'Flutter Android' : 'Flutter Mac',
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _passwordController.dispose();
    _deviceController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    state.api.baseUrl = _serverController.text.trim();
    final ok = await state.login(
      password: _passwordController.text,
      deviceName: _deviceController.text.trim(),
      platform: Platform.isAndroid ? 'android' : 'mac',
    );
    if (ok) {
      // 登录成功立即做首次全量同步；失败不阻塞进入收件箱（页面内有重试）。
      // ignore: unawaited_futures
      state.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final loading = state.loginStatus == OpStatus.loading;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('CopySync',
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('serverField'),
                    controller: _serverController,
                    decoration: const InputDecoration(labelText: '服务器地址'),
                    enabled: !loading,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('passwordField'),
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: '密码'),
                    obscureText: true,
                    enabled: !loading,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('deviceField'),
                    controller: _deviceController,
                    decoration: const InputDecoration(labelText: '设备名称'),
                    enabled: !loading,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    key: const Key('loginButton'),
                    onPressed: loading ? null : _login,
                    child: loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('登录'),
                  ),
                  if (state.loginStatus == OpStatus.error &&
                      state.loginError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        state.loginError!,
                        key: const Key('loginError'),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
