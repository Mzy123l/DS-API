import 'package:flutter/material.dart';

import '../../models.dart';
import '../../theme.dart';

/// API 配置对话框：输入 / 保存 DeepSeek API Key，选择接口协议，并分别设置
/// 快速/专家模式的自定义模型名，以及中转服务器地址（可随时改，无需重编译）。
class KeyDialog extends StatefulWidget {
  const KeyDialog({
    super.key,
    required this.initialKey,
    this.initialQuickModel,
    this.initialExpertModel,
    this.initialProtocol = ApiProtocol.anthropic,
    this.initialServerBaseUrl = defaultServerBaseUrl,
    this.initialServerToken = defaultServerToken,
    this.initialServerCertSha256 = defaultServerCertSha256,
    this.initialUseServer = true,
    required this.onSave,
  });

  final String? initialKey;
  final String? initialQuickModel;
  final String? initialExpertModel;
  final ApiProtocol initialProtocol;
  final String initialServerBaseUrl;
  final String initialServerToken;
  final String initialServerCertSha256;
  final bool initialUseServer;
  final void Function(
    String key,
    String quickModel,
    String expertModel,
    ApiProtocol protocol,
    String serverBaseUrl,
    String serverToken,
    String serverCertSha256,
    bool useServer,
  )
  onSave;

  @override
  State<KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<KeyDialog> {
  late final TextEditingController _ctrl;
  late final TextEditingController _quickModelCtrl;
  late final TextEditingController _expertModelCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _certCtrl;
  late ApiProtocol _protocol;
  late bool _useServer;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialKey ?? '');
    _quickModelCtrl = TextEditingController(
      text: widget.initialQuickModel ?? '',
    );
    _expertModelCtrl = TextEditingController(
      text: widget.initialExpertModel ?? '',
    );
    _serverCtrl = TextEditingController(text: widget.initialServerBaseUrl);
    _tokenCtrl = TextEditingController(text: widget.initialServerToken);
    _certCtrl = TextEditingController(text: widget.initialServerCertSha256);
    _protocol = widget.initialProtocol;
    _useServer = widget.initialUseServer;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _quickModelCtrl.dispose();
    _expertModelCtrl.dispose();
    _serverCtrl.dispose();
    _tokenCtrl.dispose();
    _certCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('API 配置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          TextField(
            controller: _ctrl,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'DeepSeek API Key',
              hintText: 'sk-...',
              helperText: '仅保存在本机',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_off : Icons.visibility,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '接口协议',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SegmentedButton<ApiProtocol>(
            segments: [
              for (final p in ApiProtocol.values)
                ButtonSegment<ApiProtocol>(value: p, label: Text(p.label)),
            ],
            selected: {_protocol},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _protocol = s.first),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              // 选中项的能力说明：一次请求只走一个端点
              _selectedProtocolSubtitle,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _quickModelCtrl,
            decoration: InputDecoration(
              labelText: '快速模式模型（可选）',
              hintText: '如 ${AppMode.quick.model}',
              helperText: '留空用默认模型',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _expertModelCtrl,
            decoration: InputDecoration(
              labelText: '专家模式模型（可选）',
              hintText: '如 ${AppMode.expert.model}',
              helperText: '留空用默认模型',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useServer,
              onChanged: (v) => setState(() => _useServer = v),
              title: const Text(
                '生成任务交给服务器',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: const Text(
                '后台生成，回来自动补齐',
                style: TextStyle(fontSize: 12),
              ),
            ),
            if (_useServer)
              TextField(
                controller: _serverCtrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: '服务器地址',
                  hintText: defaultServerBaseUrl,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            if (_useServer) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _tokenCtrl,
                decoration: InputDecoration(
                  labelText: '服务器口令',
                  helperText: '没有口令就留空',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _certCtrl,
                decoration: InputDecoration(
                  labelText: '服务器证书指纹（可选）',
                  helperText: '自签名证书填指纹，正式证书留空',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '取消',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
          onPressed: () {
            final typed = _ctrl.text.trim();
            // 输入框留空时沿用已保存的 Key，避免误清空
            final key = typed.isEmpty ? (widget.initialKey ?? '') : typed;
            final quick = _quickModelCtrl.text.trim();
            final expert = _expertModelCtrl.text.trim();
            widget.onSave(
              key,
              quick,
              expert,
              _protocol,
              _serverCtrl.text.trim(),
              _tokenCtrl.text.trim(),
              _certCtrl.text.trim(),
              _useServer,
            );
            Navigator.of(context).pop();
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  String get _selectedProtocolSubtitle {
    for (final p in ApiProtocol.values) {
      if (p == _protocol) return p.subtitle;
    }
    return '';
  }
}
