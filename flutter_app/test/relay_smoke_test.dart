// 端到端冒烟：客户端代码 ↔ 线上中转容器。
//
// 默认跳过（需要真实服务器），联调时手动执行：
//   flutter test test/relay_smoke_test.dart \
//     --dart-define=RELAY_SMOKE_BASE=http://<你的服务器地址>
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/net_client.dart';

/// 待联调的中转服务器地址（为空则跳过本测试）
const String relaySmokeBase = String.fromEnvironment('RELAY_SMOKE_BASE');

/// 真实 API Key（不传则跳过需要上游的流式用例）
const String relaySmokeKey = String.fromEnvironment('RELAY_SMOKE_KEY');

/// 服务器口令（服务端设置 RELAY_TOKEN 时必填）
const String relaySmokeToken = String.fromEnvironment('RELAY_SMOKE_TOKEN');

/// 自签名证书的 SHA-256 指纹（HTTPS 且用自签名证书时必填）
const String relaySmokeCertSha256 = String.fromEnvironment(
  'RELAY_SMOKE_CERT_SHA256',
);

void main() {
  test(
    '端到端：中转流式输出 + 任务快照补齐',
    () async {
      final client = DeepSeekClient(
        relayBaseUrl: relaySmokeBase,
        relayToken: relaySmokeToken,
        useRelay: true,
        // 用 App 里的证书校验实现（自签名证书按指纹放行）
        client: buildPinnedHttpClient(relaySmokeCertSha256),
      );
      var content = '';
      var reasoning = '';
      String? jobId;
      String? error;
      var done = false;

      await client.send(
        input: [
          {'role': 'user', 'content': '你好'},
        ],
        model: 'deepseek-v4-pro',
        protocol: ApiProtocol.anthropic,
        thinkingEnabled: true,
        reasoningEffort: 'high',
        apiKey: relaySmokeKey,
        onReasoningDelta: (d) => reasoning += d,
        onContentDelta: (d) => content += d,
        onReasoningTimed: (_) {},
        onDone: () => done = true,
        onError: (e) => error = e,
        onJobStarted: (id) => jobId = id,
      );

      expect(error, isNull);
      expect(jobId, isNotNull);
      expect(done, isTrue);
      expect(content, isNotEmpty);

      // 再用任务快照走一遍断线补齐路径
      var resumed = '';
      var resumeDone = false;
      String? resumeError;
      await client.resumeJob(
        jobId: jobId!,
        onSnapshot: (snapshot) => resumed = snapshot.content,
        onDone: () => resumeDone = true,
        onError: (e) => resumeError = e,
      );
      expect(resumeError, isNull);
      expect(resumeDone, isTrue);
      expect(resumed, content);
    },
    skip: relaySmokeBase.isEmpty || relaySmokeKey.isEmpty
        ? '需要 --dart-define=RELAY_SMOKE_BASE 与 RELAY_SMOKE_KEY'
        : false,
  );

  test(
    '端到端：服务器存储 + 分页接口',
    () async {
      final client = buildPinnedHttpClient(relaySmokeCertSha256);
      final base = relaySmokeBase;
      final extraHeaders = relaySmokeToken.isEmpty
          ? const <String, String>{}
          : {'x-relay-token': relaySmokeToken};

      Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
        final res = await client.post(
          Uri.parse('$base$path'),
          headers: {'Content-Type': 'application/json', ...extraHeaders},
          body: jsonEncode(body),
        );
        expect(res.statusCode, 200);
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }

      Future<Map<String, dynamic>> get(String path) async {
        final res = await client.get(
          Uri.parse('$base$path'),
          headers: extraHeaders,
        );
        expect(res.statusCode, 200);
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }

      final created = await post('/v1/conversations', {
        'title': '冒烟测试',
        'model': 'deepseek-v4-pro',
      });
      final convId = (created['id'] as num).toInt();
      expect(convId, greaterThan(0));

      for (var i = 0; i < 5; i++) {
        await post('/v1/conversations/$convId/messages', {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '冒烟第$i条',
          'reasoning': i == 1 ? '思考' : '',
          'reasoning_ms': i == 1 ? 120 : 0,
        });
      }

      // 分页：先取最新 2 条，再按游标往前翻
      final page = await get('/v1/conversations/$convId/messages?limit=2');
      expect((page['items'] as List).length, 2);
      expect(page['has_more'], isTrue);
      expect((page['items'] as List).last['content'], '冒烟第4条');

      final older = await get(
        '/v1/conversations/$convId/messages?limit=2&before_id=${page['oldest_id']}',
      );
      expect((older['items'] as List).first['content'], '冒烟第1条');
      expect((older['items'] as List).first['reasoning'], '思考');

      final conversations = await get('/v1/conversations?limit=1');
      expect((conversations['items'] as List), isNotEmpty);
      expect(conversations['items'][0]['id'], convId);

      final hits = await get('/v1/search?limit=10&q=冒烟第3条');
      expect((hits['items'] as List).length, 1);

      // 清理本次测试数据
      final deleted = await client.delete(
        Uri.parse('$base/v1/conversations/$convId'),
        headers: extraHeaders,
      );
      expect(deleted.statusCode, 200);
      client.close();
    },
    skip: relaySmokeBase.isEmpty ? '未提供 --dart-define=RELAY_SMOKE_BASE' : false,
  );
}
