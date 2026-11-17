import '../chat_repository.dart';
import '../deepseek_client.dart';
import '../net_client.dart';
import '../storage.dart';
import 'settings_controller.dart';

/// 网络客户端工厂：按当前设置构造带证书指纹校验的 HTTP 客户端、
/// DeepSeek 客户端与会话存储，并随设置变化重建存储。
class NetworkConfig {
  NetworkConfig({required this.settings, this.db});

  final SettingsController settings;

  /// 本地缓存库（ServerChatRepository 的缓存后端）。
  final AppDatabase? db;

  /// 请求客户端的创建方式：测试可注入（原 AppState.clientFactory）。
  DeepSeekClient Function()? clientFactory;

  /// 会话存储（服务器或本地）；随设置变化重建。
  ChatRepository? _repo;

  /// 证书指纹：HTTPS 中转时按指纹校验自签名证书。
  String get pinnedCertSha256 =>
      settings.serverBaseUrl.startsWith('https')
      ? settings.serverCertSha256
      : '';

  /// 新建请求客户端：按当前设置配置中转与自签名证书校验。
  ///
  /// 每个会话一个实例：多会话并行时各自的流、任务号、取消状态互不覆盖。
  DeepSeekClient newClient() {
    final client = DeepSeekClient();
    // 自签名证书：按指纹校验；正式证书/HTTP 也走同一套连接参数，
    // 避免退后台后复用已经失效的旧连接。
    client.useHttpClient(buildPinnedHttpClient(pinnedCertSha256));
    client.configure(
      relayBaseUrl: settings.serverBaseUrl,
      relayToken: settings.serverToken,
      useRelay: settings.useServer,
    );
    return client;
  }

  /// 请求客户端（外部注入优先，否则按当前设置新建）。
  DeepSeekClient createClient() => clientFactory?.call() ?? newClient();

  /// 按当前设置选择会话存储：开了服务器就用服务端存储，否则退回本地。
  ChatRepository buildRepository() {
    if (settings.useServer && settings.serverBaseUrl.trim().isNotEmpty) {
      return ServerChatRepository(
        baseUrl: settings.serverBaseUrl,
        cache: db ?? AppDatabase(),
        token: settings.serverToken,
        client: buildPinnedHttpClient(pinnedCertSha256),
      );
    }
    return LocalChatRepository(db ?? AppDatabase());
  }

  /// 当前使用的会话存储。
  ChatRepository get store => _repo ??= buildRepository();

  /// 注入固定存储（测试场景：注入后 rebuildRepository 不再覆盖它）。
  void injectRepository(ChatRepository repo) => _repo = repo;

  /// 服务器设置变化后重建存储。
  void rebuildRepository() => _repo = buildRepository();
}
