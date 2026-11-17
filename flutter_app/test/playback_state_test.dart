import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/speech.dart';
import 'package:ds_api/storage.dart';

/// 播放按钮状态的回归测试。
///
/// 根因（重构拆分引入）：`TtsController` 是独立的 ChangeNotifier，
/// 播放状态变化时它只通知**自己**的监听者；而 root_shell 用
/// `context.watch<AppState>()` 订阅 UI，AppState 没有转发 tts 的通知，
/// 于是「正在播放」永远传不到界面——按钮状态不更新。
///
/// 本测试固化这个不变量：播放状态一变，AppState 必须通知监听者。
void main() {
  test('播放状态变化时 AppState 会通知监听者（按钮能刷新）', () {
    final state = AppState(settings: SettingsStore());
    final service = SpeechService();
    state.attachSpeech(service);

    var notified = 0;
    state.addListener(() => notified++);

    // 模拟播放状态变化：loading → playing
    service.playback.value = SpeechPlaybackState.loading;
    expect(
      notified,
      greaterThan(0),
      reason: '播放状态变化没有传到 AppState，界面上的播放按钮不会刷新',
    );

    final afterFirst = notified;
    service.playback.value = SpeechPlaybackState.playing;
    expect(notified, greaterThan(afterFirst));

    final afterSecond = notified;
    service.playback.value = SpeechPlaybackState.idle;
    expect(
      notified,
      greaterThan(afterSecond),
      reason: '播放结束复位也要通知，否则按钮会一直停在播放态',
    );

    state.dispose();
  });

  test('AppState 暴露的 speech.playingKey 与语音服务一致', () {
    final state = AppState(settings: SettingsStore());
    final service = SpeechService();
    state.attachSpeech(service);

    // playingKey 是 UI 判断「是不是正在播这一条」的唯一依据
    expect(state.speech, same(service));
    expect(state.speech?.playingKey, isNull);

    state.dispose();
  });
}
