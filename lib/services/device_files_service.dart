import 'package:flutter/services.dart';

/// 文件产物桥（WP6）：Dart → Kotlin MethodChannel。
///
/// - [exportFile]：工作区文件复制到公共下载目录 `Download/TongYi-Lite/`
///   （targetSdk 33+ 走 MediaStore），返回 content:// URI；
/// - [openFile]：系统查看器打开（content URI 或应用内绝对路径）。
class DeviceFilesService {
  DeviceFilesService._();

  static final DeviceFilesService instance = DeviceFilesService._();

  static const MethodChannel _channel =
      MethodChannel('com.dgxspark.tongyilite/files');

  /// 导出文件到下载目录，成功返回 content:// URI。
  Future<String> exportFile({required String src, String? name}) async {
    return await _channel.invokeMethod<String>(
          'exportFile',
          {'src': src, if (name != null && name.isNotEmpty) 'name': name},
        ) ??
        '';
  }

  /// 用系统应用打开（html/png/pdf/md 等）。失败抛 PlatformException。
  /// [fallbackPath]：content URI 被拒时改用的工作区源文件路径
  ///（Kotlin 侧 FileProvider 分层回退；应用自有文件授权必成功）。
  Future<void> openFile(String path, {String? fallbackPath}) async {
    await _channel.invokeMethod<void>('openFile', {
      'path': path,
      if (fallbackPath != null && fallbackPath.isNotEmpty)
        'fallbackPath': fallbackPath,
    });
  }
}
