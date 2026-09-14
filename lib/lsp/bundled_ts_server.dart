/// 历史兼容占位：曾向项目写入 jsconfig.json，现已彻底移除。
/// JS checkJs 仅通过：
/// 1) 本地 tsc 临时目录虚拟配置
/// 2) LSP workspace/configuration
/// 绝不写用户项目文件。
class JsConfigBootstrap {
  @Deprecated('Never writes project jsconfig; kept only to avoid stale imports.')
  static const fileName = 'jsconfig.json';

  @Deprecated('No-op. Do not call.')
  static Future<bool> ensureForRoot(String rootPath) async => false;
}
