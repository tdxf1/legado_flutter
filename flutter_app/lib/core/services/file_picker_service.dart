import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 平台 file_picker 调用包装，via Riverpod provider 注入便于测试 fake。
///
/// BATCH-20 (F-W2B-004)：原 `BackupPage::pickDirectoryOverride` /
/// `pickFileOverride` 测试钩子收口到此处，让 widget test 通过
/// `ProviderScope.overrides` 替换 fake，避免触碰真实平台通道。
class FilePickerService {
  const FilePickerService();

  /// 弹目录选择器，返回选中目录绝对路径或 null（用户取消）。
  Future<String?> pickDirectory() {
    return FilePicker.getDirectoryPath();
  }

  /// 弹 zip 文件选择器，返回文件绝对路径或 null（用户取消 / 文件无效）。
  Future<String?> pickZipFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  }
}

final filePickerServiceProvider = Provider<FilePickerService>(
  (ref) => const FilePickerService(),
);
