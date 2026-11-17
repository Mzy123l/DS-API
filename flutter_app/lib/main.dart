import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'foreground_service.dart';
import 'speech.dart';
import 'theme.dart';
import 'ui/root_shell.dart';

/// 全局 SnackBar 宿主 key，保证在任意位置都能弹提示。
final GlobalKey<ScaffoldMessengerState> _messengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 初始化前台服务通信端口（必须在 runApp 之前）
  ForegroundTaskManager.initPort();
  runApp(const DeepSeekApp());
}

class DeepSeekApp extends StatelessWidget {
  const DeepSeekApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        // 语音服务全 App 共用一份：同一时刻只有一条音频在播、一次录音在进行
        final state = AppState();
        state.attachSpeech(SpeechService());
        return state..init();
      },
      // 最小缓解：MaterialApp 的 theme/title 等不依赖 AppState，
      // 不再用 Consumer 包住整棵路由树——任意 notifyListeners 不再重建 MaterialApp。
      // 全面收窄订阅（RootShell 等按需监听）留给后续。
      child: MaterialApp(
        title: 'DeepSeek',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.light,
        scaffoldMessengerKey: _messengerKey,
        builder: (context, child) =>
            _NoticeHost(messengerKey: _messengerKey, child: child!),
        home: const RootShell(),
      ),
    );
  }
}

/// 全局提示宿主：监听 AppState.showNotice 并统一用 SnackBar 弹出。
///
/// 之前 AppState 只设置了 noticeText 状态字段，没有任何 UI 消费，
/// 导致"未配置 API Key""请求失败"等提示完全不显示，表现为"发送没反应"。
class _NoticeHost extends StatefulWidget {
  const _NoticeHost({required this.messengerKey, required this.child});

  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Widget child;

  @override
  State<_NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<_NoticeHost> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.noticeText != null) {
      final text = state.noticeText!;
      final isError = state.noticeIsError;
      // 构造下一帧再弹，避免 SnackBar 在 build 期间报"已在使用中"
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final messenger = widget.messengerKey.currentState;
        if (messenger == null) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(text),
            behavior: SnackBarBehavior.floating,
            backgroundColor: isError ? AppColors.danger : null,
          ),
        );
        state.clearNotice();
      });
    }
    return widget.child;
  }
}
