import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'data/message_codec.dart';
import 'image_fit.dart';
import 'models.dart';
import 'speech.dart';

// 图片列编码上限随消息编解码一起收敛到 data/message_codec.dart；
// 这里转出，保持 storage.dart 原有的公开 API 不变。
export 'data/message_codec.dart'
    show encodeCachedImages, maxCachedImageJsonBytes;

/// SQLite 本地存储（会话 + 消息）。
///
/// v2 起会话/消息以服务器为准（见 [ServerChatStore]），本地库退化为缓存：
/// 主键直接用服务器 id，便于分页游标与增量合并。
/// 升级时把 v1 的表改名为 `legacy_*` 保留，等上传到服务器后再删除。
class AppDatabase {
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'deepseek_app.db');
    _db = await openDatabase(
      path,
      version: 6,
      onCreate: (db, version) => _createV2Tables(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _migrateToV2(db);
        if (oldVersion < 3) await _addImagesColumn(db);
        if (oldVersion < 4) await _addSystemPromptColumn(db);
        if (oldVersion < 5) await _addFilesColumn(db);
        if (oldVersion < 6) await _addAudioColumn(db);
      },
    );
    return _db!;
  }

  static Future<void> _createV2Tables(Database db) async {
    await db.execute(conversationsTableSql);
    await db.execute(messagesTableSql);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conv_id, id)',
    );
  }

  /// v3：消息补 `images` 列，图片消息重新进入历史/编辑时也能看到图。
  static Future<void> _addImagesColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (columns.any((c) => c['name'] == 'images')) return;
    await db.execute(
      "ALTER TABLE messages ADD COLUMN images TEXT NOT NULL DEFAULT '[]'",
    );
  }

  /// v4：会话补 `system_prompt` 列，每个会话各自保存一份系统提示词。
  static Future<void> _addSystemPromptColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(conversations)');
    if (columns.any((c) => c['name'] == 'system_prompt')) return;
    await db.execute(
      "ALTER TABLE conversations ADD COLUMN system_prompt"
      " TEXT NOT NULL DEFAULT ''",
    );
  }

  /// v5：消息补 `files` 列，存已上传文档的 file_id，重放历史时才能引用。
  static Future<void> _addFilesColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (columns.any((c) => c['name'] == 'files')) return;
    await db.execute(
      "ALTER TABLE messages ADD COLUMN files TEXT NOT NULL DEFAULT '[]'",
    );
  }

  /// v6：消息补 `audio` 列，存模型生成的音频文件路径。
  static Future<void> _addAudioColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (columns.any((c) => c['name'] == 'audio')) return;
    await db.execute(
      "ALTER TABLE messages ADD COLUMN audio TEXT NOT NULL DEFAULT '[]'",
    );
  }

  /// v1 → v2：老表改名保留（供迁移上传），再建新表；可重复执行。
  static Future<void> _migrateToV2(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    final isLegacy = columns.any((c) => c['name'] == 'image_path');
    if (isLegacy) {
      await db.execute('DROP TABLE IF EXISTS legacy_messages');
      await db.execute('DROP TABLE IF EXISTS legacy_conversations');
      await db.execute('ALTER TABLE messages RENAME TO legacy_messages');
      await db.execute(
        'ALTER TABLE conversations RENAME TO legacy_conversations',
      );
    }
    await _createV2Tables(db);
  }

  /// 缓存服务器返回的会话列表（[replace] 为 true 时先清空旧缓存）。
  Future<void> cacheConversations(
    List<Conversation> items, {
    bool replace = false,
  }) async {
    if (items.isEmpty && !replace) return;
    final db = await database;
    // 老服务端不返回 system_prompt 时，不能用空值覆盖本机已经保存的提示词；
    // 新服务端明确返回空串（表示恢复默认）时，本机此时也已是空串，不会被“救回”。
    final preserved = <int, String>{};
    final missing = [
      for (final conv in items)
        if (conv.systemPrompt.trim().isEmpty) conv.id,
    ];
    if (missing.isNotEmpty) {
      final placeholders = List.filled(missing.length, '?').join(',');
      final rows = await db.query(
        'conversations',
        columns: ['id', 'system_prompt'],
        where: 'id IN ($placeholders)',
        whereArgs: missing,
      );
      for (final row in rows) {
        final prompt = (row['system_prompt'] as String? ?? '').trim();
        if (prompt.isNotEmpty) preserved[row['id'] as int] = prompt;
      }
    }
    final batch = db.batch();
    if (replace) batch.delete('conversations');
    for (final conv in items) {
      // 老服务端不返回 system_prompt 时用本机已保存的那份覆盖，别写空
      batch.insert(
        'conversations',
        ConversationCodec.toRow(
          conv,
          systemPrompt: conv.systemPrompt.trim().isNotEmpty
              ? conv.systemPrompt
              : preserved[conv.id] ?? '',
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> createConversation(
    String title,
    String model, {
    String systemPrompt = '',
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insert('conversations', {
      'title': title,
      'model': model,
      'system_prompt': systemPrompt,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<Conversation>> listConversations() async {
    final db = await database;
    final rows = await db.query(
      'conversations',
      orderBy: 'updated_at DESC, id DESC',
    );
    return rows.map(ConversationCodec.fromRow).toList();
  }

  Future<void> renameConversation(int id, String title) async {
    final db = await database;
    await db.update(
      'conversations',
      {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 保存某个会话的系统提示词（空字符串表示回到默认值）。
  Future<void> setSystemPrompt(int id, String prompt) async {
    final db = await database;
    await db.update(
      'conversations',
      {'system_prompt': prompt},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteConversation(int id) async {
    final db = await database;
    await db.delete('messages', where: 'conv_id = ?', whereArgs: [id]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  Future<bool> conversationExists(int id) async {
    final db = await database;
    final rows = await db.query(
      'conversations',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 缓存一页消息：`replace` 会先清掉该会话旧缓存（首屏刷新用）。
  Future<void> cacheMessages(
    int convId,
    List<ChatMessage> messages, {
    bool replace = false,
  }) async {
    final db = await database;
    final batch = db.batch();
    if (replace) {
      batch.delete('messages', where: 'conv_id = ?', whereArgs: [convId]);
    }
    for (final msg in messages) {
      batch.insert(
        'messages',
        MessageCodec.toRow(convId, msg),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 用给定消息序列整体重写一条会话的消息（用于“编辑/重新生成后截断”）。
  /// 会先删除该会话原有全部消息，再按传入顺序重新插入，保证内存与库内顺序一致。
  /// 注意：不要传入流式中的空占位 assistant，否则库内会残留空白消息。
  Future<void> rewriteMessages(int convId, List<ChatMessage> msgs) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('messages', where: 'conv_id = ?', whereArgs: [convId]);
    for (final msg in msgs) {
      batch.insert('messages', MessageCodec.toRow(convId, msg));
    }
    await batch.commit(noResult: true);
  }

  /// 删除该会话第 [keep] 条之后的全部消息（编辑/重新生成的截断）。
  Future<void> truncateMessages(int convId, int keep) async {
    final db = await database;
    await db.delete(
      'messages',
      where: '''conv_id = ? AND id NOT IN (
        SELECT id FROM messages WHERE conv_id = ? ORDER BY id ASC LIMIT ?)''',
      whereArgs: [convId, convId, keep],
    );
  }

  /// 删除该会话 id >= [beforeId] 的全部消息（编辑/重新生成按消息 id 截断）。
  ///
  /// 本地缓存的 id 与服务端消息 id 一致；这样即使界面只加载了最近一页，
  /// 也不会把“窗口里的下标”误当成整段会话的保留条数。
  Future<void> truncateMessagesBefore(int convId, int beforeId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'conv_id = ? AND id >= ?',
      whereArgs: [convId, beforeId],
    );
  }

  Future<int> saveMessage(int convId, ChatMessage msg) async {
    final db = await database;
    final id = await db.insert(
      'messages',
      MessageCodec.toRow(convId, msg),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.update(
      'conversations',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [convId],
    );
    return id;
  }

  /// 读取消息：默认全部升序；给了 [limit] 就取「最近 limit 条」并升序返回。
  Future<List<ChatMessage>> loadMessages(
    int convId, {
    int? limit,
    int? beforeId,
  }) async {
    try {
      return await _queryMessages(convId, limit: limit, beforeId: beforeId);
    } catch (_) {
      // 历史数据里可能残留超大图片行（几 MB 的 base64 塞在一行），
      // Android 的 CursorWindow 装不下会整页查询失败。
      // 这里退化成「不读图片列」，保证会话仍然打得开（联网时图片从服务器补）。
      return await _queryMessages(
        convId,
        limit: limit,
        beforeId: beforeId,
        withImages: false,
      );
    }
  }

  Future<List<ChatMessage>> _queryMessages(
    int convId, {
    int? limit,
    int? beforeId,
    bool withImages = true,
  }) async {
    final db = await database;
    final where = StringBuffer('conv_id = ?');
    final args = <Object?>[convId];
    if (beforeId != null) {
      where.write(' AND id < ?');
      args.add(beforeId);
    }
    final order = limit == null ? 'id ASC' : 'id DESC';
    final tail = limit == null ? '' : ' LIMIT $limit';
    final columns = withImages
        ? '*'
        : "id, conv_id, role, content, reasoning, reasoning_ms, sources, "
              "files, audio, ts, '[]' AS images";
    final rows = await db.rawQuery(
      'SELECT $columns FROM messages WHERE $where ORDER BY $order$tail',
      args,
    );
    final messages = rows.map(MessageCodec.fromRow).toList();
    return limit == null ? messages : messages.reversed.toList();
  }

  // ------------------------------------------------------ v1 数据迁移

  /// 是否存在待上传的 v1 本地数据。
  Future<bool> hasLegacyData() async {
    final db = await database;
    final table = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'"
      " AND name='legacy_conversations'",
    );
    if (table.isEmpty) return false;
    final count = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM legacy_conversations',
    );
    return (count.first['n'] as int? ?? 0) > 0;
  }

  Future<List<Conversation>> loadLegacyConversations() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT id, title, model, updated_at FROM legacy_conversations'
      ' ORDER BY id ASC',
    );
    return [
      for (final row in rows)
        Conversation(
          id: row['id'] as int,
          title: row['title'] as String? ?? '新对话',
          model: row['model'] as String? ?? '',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            row['updated_at'] as int? ?? 0,
          ),
        ),
    ];
  }

  Future<List<ChatMessage>> loadLegacyMessages(int convId) async {
    final db = await database;
    final rows = await db.query(
      'legacy_messages',
      where: 'conv_id = ?',
      whereArgs: [convId],
      orderBy: 'id ASC',
    );
    return [
      for (final row in rows)
        ChatMessage(
          role: row['role'] == 'user'
              ? MessageRole.user
              : MessageRole.assistant,
          content: row['content'] as String? ?? '',
          reasoning: row['reasoning'] as String? ?? '',
          reasoningMs: row['reasoning_ms'] as int? ?? 0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            row['ts'] as int? ?? 0,
          ),
        ),
    ];
  }

  Future<void> dropLegacy() async {
    final db = await database;
    await db.execute('DROP TABLE IF EXISTS legacy_messages');
    await db.execute('DROP TABLE IF EXISTS legacy_conversations');
  }

  /// 在会话消息正文里做子串搜索（不区分大小写），返回消息级命中（新的在前）。
  ///
  /// 与官方搜索一致：结果是“消息”而不是“会话”，并带上命中位置以便展示片段。
  Future<List<MessageHit>> searchMessages(
    String query, {
    int limit = 300,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final db = await database;
    // LIKE 里的通配符需要转义，避免用户输入 % / _ 后被当作通配
    final escaped = q
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final rows = await db.rawQuery(
      '''
      SELECT m.conv_id, m.role, m.content, m.ts, c.title
      FROM messages m JOIN conversations c ON c.id = m.conv_id
      WHERE m.content LIKE ? ESCAPE '\\'
      ORDER BY m.ts DESC
      LIMIT ?
      ''',
      ['%$escaped%', limit],
    );
    final hits = <MessageHit>[];
    for (final r in rows) {
      final content = r['content'] as String? ?? '';
      final matches = _matchIndexes(content, q);
      if (matches.isEmpty) continue;
      hits.add(
        MessageHit(
          conversationId: r['conv_id'] as int,
          conversationTitle: r['title'] as String? ?? '',
          role: r['role'] == 'user' ? MessageRole.user : MessageRole.assistant,
          content: content,
          timestamp: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
          matches: matches,
        ),
      );
    }
    return hits;
  }

  /// 统计 query 在 content 中出现的字符下标（忽略大小写）。
  static List<int> _matchIndexes(String content, String query) {
    if (query.isEmpty) return const [];
    final haystack = content.toLowerCase();
    final needle = query.toLowerCase();
    final out = <int>[];
    var from = 0;
    while (out.length < 50) {
      final idx = haystack.indexOf(needle, from);
      if (idx < 0) break;
      out.add(idx);
      from = idx + needle.length;
    }
    return out;
  }
}

/// 应用设置（API Key / 模式 / 深度思考 / 联网搜索）存 SharedPreferences。
class SettingsStore {
  static const _kApiKey = 'api_key';
  static const _kMode = 'mode';
  static const _kDeepThink = 'deep_think';
  static const _kWebSearch = 'web_search';
  static const _kReasoningEffort = 'reasoning_effort';
  static const _kApiProtocol = 'api_protocol';
  static const _kModelOverrideQuick = 'model_override_quick';
  static const _kModelOverrideExpert = 'model_override_expert';
  static const _kUseServer = 'use_server';
  static const _kServerBaseUrl = 'server_base_url';
  static const _kServerToken = 'server_token';
  static const _kServerCertSha256 = 'server_cert_sha256';
  static const _kPendingJob = 'pending_job';
  static const _kLegacyImported = 'legacy_imported';

  /// 朗读音色（`stella` / `tide`）
  static const _kTtsVoice = 'tts_voice';

  /// 自动朗读开关
  static const _kAutoSpeak = 'auto_speak';

  /// 各会话的朗读括号模式（JSON：{conv_id: 'speak'|'skip'}）
  static const _kBracketModeByConv = 'bracket_mode_by_conversation';

  /// 各会话的「语音生成工具」开关（JSON：{conv_id: bool}）
  static const _kTtsToolByConv = 'tts_tool_by_conversation';

  /// 开启了「回答气泡」的会话 id 列表（仅本地，不改服务端）。
  static const _kAnswerBubbleIds = 'answer_bubble_ids';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get prefs async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<String?> get apiKey async => (await prefs).getString(_kApiKey);

  /// 该会话是否开启了「回答气泡」。
  Future<bool> answerBubbleFor(int conversationId) async {
    final ids = (await prefs).getStringList(_kAnswerBubbleIds) ?? const [];
    return ids.contains(conversationId.toString());
  }

  /// 记录会话的「回答气泡」开关。
  Future<void> setAnswerBubbleFor(int conversationId, bool enabled) async {
    final sp = await prefs;
    final ids = (sp.getStringList(_kAnswerBubbleIds) ?? const [])
        .where((e) => e != conversationId.toString())
        .toList();
    if (enabled) ids.add(conversationId.toString());
    await sp.setStringList(_kAnswerBubbleIds, ids);
  }

  Future<void> setApiKey(String? key) async {
    final sp = await prefs;
    if (key == null || key.isEmpty) {
      await sp.remove(_kApiKey);
    } else {
      await sp.setString(_kApiKey, key.trim());
    }
  }

  Future<String?> get modelOverrideQuick async =>
      (await prefs).getString(_kModelOverrideQuick);

  Future<void> setModelOverrideQuick(String? value) async {
    final sp = await prefs;
    if (value == null || value.trim().isEmpty) {
      await sp.remove(_kModelOverrideQuick);
    } else {
      await sp.setString(_kModelOverrideQuick, value.trim());
    }
  }

  Future<String?> get modelOverrideExpert async =>
      (await prefs).getString(_kModelOverrideExpert);

  Future<void> setModelOverrideExpert(String? value) async {
    final sp = await prefs;
    if (value == null || value.trim().isEmpty) {
      await sp.remove(_kModelOverrideExpert);
    } else {
      await sp.setString(_kModelOverrideExpert, value.trim());
    }
  }

  Future<int> get mode async => (await prefs).getInt(_kMode) ?? 0;

  Future<void> setMode(int index) async => (await prefs).setInt(_kMode, index);

  Future<bool> get deepThink async =>
      (await prefs).getBool(_kDeepThink) ?? true;

  Future<void> setDeepThink(bool value) async =>
      (await prefs).setBool(_kDeepThink, value);

  Future<bool> get webSearch async =>
      (await prefs).getBool(_kWebSearch) ?? false;

  Future<void> setWebSearch(bool value) async =>
      (await prefs).setBool(_kWebSearch, value);

  Future<String> get reasoningEffort async =>
      (await prefs).getString(_kReasoningEffort) ?? defaultReasoningEffort;

  Future<void> setReasoningEffort(String value) async =>
      (await prefs).setString(_kReasoningEffort, value);

  /// 接口协议下标（见 [ApiProtocol]）；未设置时返回 null 由调用方取默认值。
  Future<int?> get apiProtocol async => (await prefs).getInt(_kApiProtocol);

  Future<void> setApiProtocol(int index) async =>
      (await prefs).setInt(_kApiProtocol, index);

  /// 是否把请求交给中转服务器执行（默认开启）。
  Future<bool> get useServer async =>
      (await prefs).getBool(_kUseServer) ?? true;

  Future<void> setUseServer(bool value) async =>
      (await prefs).setBool(_kUseServer, value);

  /// 中转服务器地址；未设置或留空时回退到 [defaultServerBaseUrl]。
  Future<String> get serverBaseUrl async {
    final stored = (await prefs).getString(_kServerBaseUrl)?.trim() ?? '';
    return stored.isEmpty ? defaultServerBaseUrl : stored;
  }

  Future<void> setServerBaseUrl(String value) async {
    final sp = await prefs;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == defaultServerBaseUrl) {
      await sp.remove(_kServerBaseUrl);
    } else {
      await sp.setString(_kServerBaseUrl, trimmed);
    }
  }

  /// 服务器访问口令；未设置时用构建时注入的默认值。
  Future<String> get serverToken async {
    final stored = (await prefs).getString(_kServerToken)?.trim() ?? '';
    return stored.isEmpty ? defaultServerToken : stored;
  }

  Future<void> setServerToken(String value) async {
    final sp = await prefs;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == defaultServerToken) {
      await sp.remove(_kServerToken);
    } else {
      await sp.setString(_kServerToken, trimmed);
    }
  }

  /// 服务器证书指纹；未设置时用构建时注入的默认值。
  Future<String> get serverCertSha256 async {
    final stored = (await prefs).getString(_kServerCertSha256)?.trim() ?? '';
    return stored.isEmpty ? defaultServerCertSha256 : stored;
  }

  Future<void> setServerCertSha256(String value) async {
    final sp = await prefs;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == defaultServerCertSha256) {
      await sp.remove(_kServerCertSha256);
    } else {
      await sp.setString(_kServerCertSha256, trimmed);
    }
  }

  /// 正在服务器上执行的任务（JSON：job_id / conversation_id）；
  /// 用于 App 重开后把没看完的回答补齐。
  Future<String?> get pendingJob async => (await prefs).getString(_kPendingJob);

  Future<void> setPendingJob(String? value) async {
    final sp = await prefs;
    if (value == null || value.isEmpty) {
      await sp.remove(_kPendingJob);
    } else {
      await sp.setString(_kPendingJob, value);
    }
  }

  /// v1 本地历史是否已上传到服务器（迁移只做一次）。
  Future<bool> get legacyImported async =>
      (await prefs).getBool(_kLegacyImported) ?? false;

  Future<void> setLegacyImported(bool value) async =>
      (await prefs).setBool(_kLegacyImported, value);

  /// 朗读音色；未设置时为官方默认的 `stella`。
  ///
  /// 目前官方只开放一种音色，界面不提供切换；这里保留读写接口，
  /// 后续官方新增音色时直接可用。
  Future<String> get ttsVoice async {
    final stored = (await prefs).getString(_kTtsVoice)?.trim() ?? '';
    return stored.isEmpty ? defaultTtsVoiceId : stored;
  }

  Future<void> setTtsVoice(String voiceId) async {
    final sp = await prefs;
    final trimmed = voiceId.trim();
    if (trimmed.isEmpty || trimmed == defaultTtsVoiceId) {
      await sp.remove(_kTtsVoice);
    } else {
      await sp.setString(_kTtsVoice, trimmed);
    }
  }

  /// 自动朗读开关（默认关闭）。
  Future<bool> get autoSpeak async =>
      (await prefs).getBool(_kAutoSpeak) ?? false;

  Future<void> setAutoSpeak(bool value) async =>
      (await prefs).setBool(_kAutoSpeak, value);

  /// 某个会话的括号朗读模式；没有单独设置时默认朗读括号内容。
  Future<BracketSpeechMode> bracketModeFor(int conversationId) async {
    final map = _decodeStringMap(
      (await prefs).getString(_kBracketModeByConv),
    );
    return map[conversationId.toString()] == 'skip'
        ? BracketSpeechMode.skip
        : BracketSpeechMode.speak;
  }

  Future<void> setBracketModeFor(int conversationId, BracketSpeechMode mode) async {
    final sp = await prefs;
    final map = _decodeStringMap(sp.getString(_kBracketModeByConv));
    // 默认（朗读括号）不写条目，只有显式跳过才记
    if (mode == BracketSpeechMode.speak) {
      map.remove(conversationId.toString());
    } else {
      map[conversationId.toString()] = 'skip';
    }
    if (map.isEmpty) {
      await sp.remove(_kBracketModeByConv);
    } else {
      await sp.setString(_kBracketModeByConv, jsonEncode(map));
    }
  }

  /// 某个会话是否启用语音生成工具；没有单独设置时默认关闭。
  Future<bool> ttsToolFor(int conversationId) async {
    final map = _decodeBoolMap((await prefs).getString(_kTtsToolByConv));
    return map[conversationId.toString()] ?? false;
  }

  Future<void> setTtsToolFor(int conversationId, bool enabled) async {
    final sp = await prefs;
    final map = _decodeBoolMap(sp.getString(_kTtsToolByConv));
    map[conversationId.toString()] = enabled;
    await sp.setString(_kTtsToolByConv, jsonEncode(map));
  }

  Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String)
            entry.key.toString(): entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  Map<String, bool> _decodeBoolMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is bool) entry.key.toString(): entry.value as bool,
      };
    } catch (_) {
      return {};
    }
  }
}

/// 明显二进制的扩展名：按后缀过滤，直接拒绝挂载。
const Set<String> _binaryExtensions = {
  // 图片（走图片通道，不按文本处理）
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'ico',
  'heic',
  'avif',
  'tif',
  'tiff',
  // 音视频
  'mp4',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'webm',
  'm4v',
  'mp3',
  'wav',
  'ogg',
  'flac',
  'aac',
  'm4a',
  'opus',
  // 压缩包
  'zip',
  'rar',
  '7z',
  'tar',
  'gz',
  'bz2',
  'xz',
  'zst',
  'jar',
  'war',
  'apk',
  'aab',
  'ar',
  // 可执行 / 库 / 数据
  'exe',
  'dll',
  'so',
  'dylib',
  'a',
  'o',
  'obj',
  'lib',
  'bin',
  'dat',
  'db',
  'sqlite',
  'dex',
  'class',
  'deb', 'rpm', 'appimage',
  // 文档（非纯文本格式）
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp',
  // 字体 / 镜像 / 密钥文件
  'ttf',
  'otf',
  'woff',
  'woff2',
  'iso',
  'img',
  'dmg',
  'keystore',
  'jks',
  'p12',
  'pfx',
};

/// 官方 Files API 支持的文档后缀（PDF / Word / PowerPoint）。
const Set<String> documentExtensions = {
  '.pdf',
  '.doc',
  '.docx',
  '.ppt',
  '.pptx',
};

/// 是否为需要走 Files API 的文档（PDF / Office）。
bool isDocumentPath(String path) {
  final lower = path.toLowerCase();
  return documentExtensions.any(lower.endsWith);
}

/// 加载文件附件：
/// - 图片：按**真实内容**判断格式后返回 data URL（走 input_image）；
/// - 文本文件：读取内容，模型可直接读取；
/// - PDF / Office：标记为 document，发送前再上传 Files API；
/// - 明显二进制（后缀或内容）或不支持的图片格式：返回 null，调用方提示并过滤。
Future<Attachment?> loadFileAttachment(String path) async {
  final f = File(path);
  if (!await f.exists()) return null;
  final bytes = await f.readAsBytes();
  final lower = path.toLowerCase();

  // 图片一律以文件内容为准：扩展名只有 .jpg、内容却是 HEIC/AVIF 的情况
  // 并不少见，照扩展名发出去上游只会回一句 unsupported image。
  final probe = probeImage(bytes);
  if (probe.isKnown) {
    if (!probe.supported) return null;
    final prepared = await prepareImageForApi(bytes);
    if (prepared == null) return null;
    return Attachment(
      path: path,
      dataUrl:
          'data:${prepared.mediaType};base64,'
          '${bytesToBase64(prepared.bytes)}',
      sizeBytes: prepared.bytes.length,
    );
  }

  // PDF / Word / PowerPoint：交给官方 Files API 解析（能读扫描件与图表）
  if (isDocumentPath(path)) {
    if (bytes.length > 100 * 1024 * 1024) return null;
    return Attachment(
      path: path,
      dataUrl: 'data:application/octet-stream;base64,',
      kind: AttachmentKind.document,
      sizeBytes: bytes.length,
    );
  }

  final mime = _mimeTypeFor(lower);
  final dot = lower.lastIndexOf('.');
  final ext = dot >= 0 ? lower.substring(dot + 1) : '';
  // 明显二进制后缀直接过滤
  if (_binaryExtensions.contains(ext)) return null;
  // 内容嗅探（NUL 字节 / 常见魔数）
  if (looksBinary(bytes)) return null;
  final text = _decodeText(bytes);
  if (text == null) return null;
  return Attachment(
    path: path,
    dataUrl: 'data:$mime;base64,${bytesToBase64(bytes)}',
    textContent: text,
    kind: AttachmentKind.text,
    sizeBytes: bytes.length,
  );
}

/// 文件大小展示（4.43KB / 1.2MB），与官方一致保留两位有效数字。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0B';
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    return '${_trimZero(bytes / 1024)}KB';
  }
  return '${_trimZero(bytes / 1024 / 1024)}MB';
}

String _trimZero(double value) {
  final text = value.toStringAsFixed(2);
  return text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

/// 扩展名看起来像图片（用于把「不支持的图片格式」和普通文件区分开）。
bool looksLikeImagePath(String path) {
  final lower = path.toLowerCase();
  const extensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.jpe',
    '.jfif',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
    '.heif',
    '.avif',
    '.tif',
    '.tiff',
  };
  return extensions.any(lower.endsWith);
}

/// 是否疑似二进制（含 NUL 字节或常见二进制魔数）。
bool looksBinary(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  for (final b in bytes) {
    if (b == 0) return true;
  }
  if (bytes.length >= 4) {
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true; // JPEG
    }
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true; // GIF
    }
    if (bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      return true; // ZIP
    }
    if (bytes[0] == 0x7F &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4C &&
        bytes[3] == 0x46) {
      return true; // ELF
    }
    if (bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46) {
      return true; // PDF
    }
  }
  return false;
}

/// 解码文本：优先严格 UTF-8，失败再用 latin1 容错；仍失败返回 null。
String? _decodeText(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {}
  try {
    return latin1.decode(bytes);
  } catch (_) {}
  return null;
}

/// 根据扩展名推断非图片附件的 MIME。
///
/// 图片不在这里判断：格式一律以文件内容为准（见 [probeImage]）。
String _mimeTypeFor(String path) {
  if (path.endsWith('.pdf')) return 'application/pdf';
  if (path.endsWith('.txt')) return 'text/plain';
  if (path.endsWith('.md')) return 'text/markdown';
  if (path.endsWith('.csv')) return 'text/csv';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.doc')) return 'application/msword';
  if (path.endsWith('.docx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (path.endsWith('.xls')) return 'application/vnd.ms-excel';
  if (path.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (path.endsWith('.zip')) return 'application/zip';
  return 'application/octet-stream';
}

// Dart 3.13 自带 base64Encode，这里直接引用 dart:convert。
String bytesToBase64(List<int> bytes) => base64Encode(bytes);
