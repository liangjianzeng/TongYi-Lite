/// 外部应用桥（MethodChannel：com.dgxspark.tongyilite/app）。
///
/// Termux SSH 向导用：检测 Termux 是否安装、一键拉起 Termux App——
/// sshd 未启动时用户不用回桌面找图标。
library;

import 'package:flutter/services.dart';

class AppBridge {
  static const MethodChannel _ch =
      MethodChannel('com.dgxspark.tongyilite/app');

  /// Termux 官方包名（F-Droid/GitHub 版；Play 商店变体同 id）。
  static const String termuxPackage = 'com.termux';

  /// 应用是否已安装。异常按未安装处理。
  static Future<bool> isAppInstalled(String package) async {
    try {
      return await _ch.invokeMethod<bool>('isAppInstalled',
              <String, dynamic>{'package': package}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// 拉起应用主界面。失败（未安装/被禁）返回 false。
  static Future<bool> launchApp(String package) async {
    try {
      return await _ch.invokeMethod<bool>('launchApp',
              <String, dynamic>{'package': package}) ==
          true;
    } catch (_) {
      return false;
    }
  }
}
