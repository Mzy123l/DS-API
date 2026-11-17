import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务：在模型生成回答期间保持进程存活，退到后台仍持续接收流式输出。
///
/// 实际的 SSE 流式仍运行在主 isolate（见 [deepseek_client.dart]）；
/// 这里仅启动一个常驻通知的前台服务，避免 Android 在应用退后台后
/// 回收进程 / 冻结网络连接，从而解决“退后台后输出不再继续接收”的问题。
class ForegroundTaskManager {
  ForegroundTaskManager._();

  static bool _inited = false;

  /// 在 main() 中调用，初始化与后台服务隔离通信的端口。
  static void initPort() {
    FlutterForegroundTask.initCommunicationPort();
  }

  static Future<void> ensureInit() async {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ds_api_generation',
        channelName: '回答生成中',
        channelDescription: 'DeepSeek 生成回答时保持应用运行',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
        // 用户从最近任务划掉应用时停止服务；仅退后台（Home 键）时保持运行
        stopWithTask: true,
      ),
    );
    _inited = true;
  }

  /// 生成开始时启动后台保活。
  ///
  /// 刻意不被调用方 await，避免阻塞 UI 的流式更新。
  static Future<void> start() async {
    if (kIsWeb) return;
    try {
      await ensureInit();
      if (Platform.isAndroid) {
        // Android 13+ 需要通知权限才能展示前台服务通知（不授权也能运行服务）
        final permission =
            await FlutterForegroundTask.checkNotificationPermission();
        if (permission != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
      }
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 101,
        notificationTitle: 'DeepSeek',
        notificationText: '正在生成回答，请稍候…',
        callback: _startCallback,
      );
    } catch (_) {
      // 平台不支持（桌面、单元测试等）时忽略：保活失败不影响生成本身
    }
  }

  /// 生成结束 / 中断时停止保活。
  static Future<void> stop() async {
    if (kIsWeb) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // 同上：取消失败无需打扰用户
    }
  }
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

/// 保活用任务处理器：不执行实际逻辑，仅维持前台服务运行。
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationDismissed() {}
}
