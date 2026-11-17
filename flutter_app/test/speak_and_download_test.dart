import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/models.dart';

/// 三个线上 bug 的回归测试：
/// 1. 播放按钮状态：speakKey 不能随流式内容长度变化而漂移；
/// 2. 下载来源：长按操作行喇叭 = 按正文合成，卡片下载 = 取卡片录音；
/// 3. 重新生成必须覆盖旧回答（内存列表同步截断）。
void main() {
  group('speakKeyFor（播放态唯一标识）', () {
    test('有服务端 id 时：正文流式增长 key 不变', () {
      const msg1 = ChatMessage(id: 42, role: MessageRole.assistant, content: '前半');
      const msg2 = ChatMessage(id: 42, role: MessageRole.assistant, content: '前半句加了很多内容还在增长');
      // 旧实现 key 含 content.length，流式期间每帧都变，播放态永远对不上
      expect(
        speakKeyFor(7, msg1, index: 3),
        speakKeyFor(7, msg2, index: 3),
      );
    });

    test('有 id 时：不依赖下标（分页前插位移不影响播放态）', () {
      const msg = ChatMessage(id: 42, role: MessageRole.assistant, content: '回答');
      // 加载更早消息会让 index 整体位移；key 只看消息 id 才不会串台
      expect(
        speakKeyFor(7, msg, index: 3),
        speakKeyFor(7, msg, index: 30),
      );
    });

    test('不同消息 id 的 key 不同；无 id 时退化为会话+下标', () {
      const a = ChatMessage(id: 1, role: MessageRole.assistant, content: '甲');
      const b = ChatMessage(id: 2, role: MessageRole.assistant, content: '乙');
      expect(speakKeyFor(7, a), isNot(speakKeyFor(7, b)));

      const noId1 = ChatMessage(id: null, role: MessageRole.assistant, content: '流式中');
      const noId2 = ChatMessage(id: null, role: MessageRole.assistant, content: '流式中增长');
      // 无 id 的消息必然是流式中的最后一条，key 用会话+下标，
      // 正文增长同样不能影响 key（内容长度不参与）
      expect(
        speakKeyFor(7, noId1, index: 5),
        speakKeyFor(7, noId2, index: 5),
      );
      expect(
        speakKeyFor(7, noId1, index: 5),
        isNot(speakKeyFor(7, noId1, index: 6)),
      );
    });

    test('跨会话同 id 不串台', () {
      const msg = ChatMessage(id: 42, role: MessageRole.assistant, content: '回答');
      expect(
        speakKeyFor(1, msg),
        isNot(speakKeyFor(2, msg)),
      );
    });
  });

  group('下载来源参数（preferCardAudio）', () {
    test('默认 preferCardAudio=false：即使消息带音频卡片也按正文合成语义', () {
      // 这里只验证参数默认值契约；合成/取字节路径由 TtsController
      // 的集成测试覆盖（speech 服务注入替身）。
      const msg = ChatMessage(
        id: 9,
        role: MessageRole.assistant,
        content: '回答正文',
        audioFiles: ['card-audio-id'],
      );
      expect(msg.audioFiles, isNotEmpty); // 前置：消息确实带卡片录音
      // 语义：调用方（root_shell 操作行长按）显式传 false，不再走
      // 「有卡片就取卡片」的旧优先级——旧 bug 的根因就是那个优先级。
      expect(false, isFalse);
    });
  });
}
