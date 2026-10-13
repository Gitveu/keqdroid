import 'package:shared_preferences/shared_preferences.dart';

class ResumeAfterUpdate {
  ResumeAfterUpdate._();

  static const _key = 'resume_vpn_after_update_at';

  static const maxAge = Duration(minutes: 30);

  static Future<void> mark({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, (now ?? DateTime.now()).millisecondsSinceEpoch);
  }

  static Future<bool> take({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_key);
    if (at == null) return false;
    await prefs.remove(_key);
    final age = (now ?? DateTime.now()).difference(
      DateTime.fromMillisecondsSinceEpoch(at),
    );
    // часы могли уйти назад между запусками
    return age.abs() <= maxAge;
  }
}
