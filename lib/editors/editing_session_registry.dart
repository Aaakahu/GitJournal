/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/// 编辑租约：登记当前正被编辑器会话持有的 note 路径。
///
/// App 内同步（repository.dart 的 syncNotes -> _loadNotes）重载文件后产生的
/// 新 Note 对象，不得回流进仍打开着的编辑器覆盖正文：租约期间的编辑器内容
/// 以编辑会话为准（同步重载被跳过），退出编辑时由保存/重开自然拉新。
///
/// 单例 Map：notePath -> 是否持有租约（存在即持有）。
abstract final class EditingSessionRegistry {
  static final Map<String, bool> _sessions = <String, bool>{};

  /// 编辑器打开 note 时登记租约。
  static void beginSession(String notePath) => _sessions[notePath] = true;

  /// 编辑器关闭（dispose）时注销租约。
  static void endSession(String notePath) => _sessions.remove(notePath);

  /// 该路径当前是否被某个编辑会话持有。
  static bool isBeingEdited(String notePath) =>
      _sessions.containsKey(notePath);
}
