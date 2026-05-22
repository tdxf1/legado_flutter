import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'remote_book_runner.dart' show RemoteBookProgress;
import 'update_toc_runner.dart' show UpdateTocProgress;

class NotificationService {
  static const _channel = MethodChannel('legado/notifications');
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Must match MainActivity.kt DOWNLOAD_CHANNEL_ID
  static const String _downloadChannelId = 'legado_download';
  static const String _downloadChannelName = '下载通知';

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings('ic_notification');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        ),
      );

      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        final channel = AndroidNotificationChannel(
          _downloadChannelId,
          _downloadChannelName,
          description: '书籍下载进度通知',
          importance: Importance.low,
        );
        await androidPlugin.createNotificationChannel(channel);
      }
    } catch (e) {
      debugPrint('[Notification] init failed: $e');
      _initialized = false;
    }
  }

  static Future<void> showDownloadProgress({
    required int id,
    required String title,
    required int current,
    required int total,
  }) async {
    final progress = total > 0 ? current * 100 ~/ total : 0;
    try {
      if (!await hasPermission()) return;
      await _plugin.show(
        id,
        title,
        '下载中 $current/$total ($progress%)',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _downloadChannelId,
            _downloadChannelName,
            channelDescription: '书籍下载进度通知',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: total,
            progress: current,
            icon: 'ic_notification',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentBadge: true,
            presentSound: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Notification] showDownloadProgress failed: $e');
    }
  }

  static Future<void> showDownloadComplete({
    required int id,
    required String title,
    required int successCount,
    required int failCount,
    required int skipCount,
  }) async {
    final hasFailures = failCount > 0 || skipCount > 0;
    try {
      if (!await hasPermission()) return;
      await _plugin.show(
        id,
        title,
        hasFailures
            ? '完成 (成功: $successCount, 失败: $failCount, 跳过: $skipCount)'
            : '下载完成 ($successCount 章)',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _downloadChannelId,
            _downloadChannelName,
            channelDescription: '书籍下载进度通知',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: false,
            autoCancel: true,
            icon: 'ic_notification',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Notification] showDownloadComplete failed: $e');
    }
  }

  static Future<void> cancelNotification(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (e) {
      debugPrint('[Notification] cancel($id) failed: $e');
    }
  }

  /// BATCH-27b: 批量「更新目录」进度通知。与
  /// [showDownloadProgress] / [showDownloadComplete] 同模式，但只用一个
  /// 方法（progress.isDone 决定 ongoing / autoCancel / 文案）。
  ///
  /// notificationId 99001（与 download 99000 区分），让用户同时跑下载 +
  /// 刷目录时两个 notification 不互相覆盖。
  static Future<void> showUpdateTocProgress(UpdateTocProgress progress) async {
    try {
      if (!await hasPermission()) return;
      if (progress.isDone) {
        await _plugin.show(
          99001,
          '目录刷新完成',
          progress.fail > 0
              ? '完成 (成功: ${progress.success}, 失败: ${progress.fail})'
              : '已刷新 ${progress.success} 本',
          NotificationDetails(
            android: AndroidNotificationDetails(
              _downloadChannelId,
              _downloadChannelName,
              channelDescription: '书架批量任务进度',
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
              ongoing: false,
              autoCancel: true,
              icon: 'ic_notification',
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              // BATCH-27b spec「批量任务 + Notification 通道契约」: isDone
              // 阶段 presentSound: true 提醒用户（与 showDownloadComplete
              // 同款 / spec 段「ongoing/autoCancel 二段」决策一致）。
              presentSound: true,
            ),
          ),
        );
        return;
      }
      if (progress.total <= 0) return; // 空批不显示通知
      await _plugin.show(
        99001,
        '正在更新目录...',
        '${progress.processed}/${progress.total}'
        '${progress.fail > 0 ? '  (失败: ${progress.fail})' : ''}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _downloadChannelId,
            _downloadChannelName,
            channelDescription: '书架批量任务进度',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: progress.total,
            progress: progress.processed,
            icon: 'ic_notification',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentBadge: true,
            presentSound: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Notification] showUpdateTocProgress failed: $e');
    }
  }

  /// BATCH-27c-3: 远程书批量下载进度通知。与 [showUpdateTocProgress] 同模式
  /// （progress.isDone 决定 ongoing / autoCancel / 文案）。
  ///
  /// notificationId 99002（与 download 99000 / update_toc 99001 区分），
  /// 让用户同时跑下载 + 刷目录 + 远程书入库时三个 notification 不互相覆盖。
  static Future<void> showRemoteBookProgress(
      RemoteBookProgress progress) async {
    try {
      if (!await hasPermission()) return;
      if (progress.isDone) {
        await _plugin.show(
          99002,
          '远程书入库完成',
          progress.fail > 0
              ? '完成 (成功: ${progress.success}, 失败: ${progress.fail})'
              : '已入库 ${progress.success} 本',
          NotificationDetails(
            android: AndroidNotificationDetails(
              _downloadChannelId,
              _downloadChannelName,
              channelDescription: '书架批量任务进度',
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
              ongoing: false,
              autoCancel: true,
              icon: 'ic_notification',
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              // BATCH-27b spec「批量任务 + Notification 通道契约」: isDone
              // 阶段 presentSound: true 提醒用户。
              presentSound: true,
            ),
          ),
        );
        return;
      }
      if (progress.total <= 0) return; // 空批不显示通知
      await _plugin.show(
        99002,
        '远程书下载中',
        '${progress.processed}/${progress.total}'
        '${progress.fail > 0 ? '  (失败: ${progress.fail})' : ''}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _downloadChannelId,
            _downloadChannelName,
            channelDescription: '书架批量任务进度',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: progress.total,
            progress: progress.processed,
            icon: 'ic_notification',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentBadge: true,
            presentSound: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Notification] showRemoteBookProgress failed: $e');
    }
  }

  static Future<bool> hasPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasPermission');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod('openNotificationSettings');
    } on MissingPluginException {
    } on PlatformException {}
  }
}
