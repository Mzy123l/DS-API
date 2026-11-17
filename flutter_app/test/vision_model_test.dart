import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/models.dart';

void main() {
  test('官方支持识图的模型不换路', () {
    for (final model in [
      'deepseek-flash',
      'deepseek-v4-flash',
      'deepseek-v4-flash-vision-exp',
      'my-custom-model',
    ]) {
      expect(modelSupportsVision(model), isTrue, reason: model);
      expect(modelForRequest(model, hasImages: true), model, reason: model);
    }
  });

  test('deepseek-v4-pro / claude-opus 不支持识图，带图时改走快速模型', () {
    for (final model in ['deepseek-v4-pro', 'claude-opus-4-8']) {
      expect(modelSupportsVision(model), isFalse, reason: model);
      expect(modelForRequest(model, hasImages: true), visionModel);
      // 纯文字请求保持用户选的模型
      expect(modelForRequest(model, hasImages: false), model);
    }
  });

  test('input 里任意一条消息带图就算带图请求', () {
    final input = <Map<String, dynamic>>[
      {'role': 'user', 'content': '你好'},
      {
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': '看图'},
          {
            'type': 'input_image',
            'image_url': 'data:image/png;base64,AA',
            'detail': 'low',
          },
        ],
      },
    ];
    expect(inputHasImages(input), isTrue);
    expect(
      inputHasImages([
        {'role': 'user', 'content': '纯文字'},
      ]),
      isFalse,
    );
  });
}
