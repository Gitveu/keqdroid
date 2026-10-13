#ifndef RUNNER_WINDOWS_HOTKEYS_H_
#define RUNNER_WINDOWS_HOTKEYS_H_

#include <windows.h>

#include <string>
#include <vector>

// привязки шлёт Dart, WM_HOTKEY уходит обратно как onHotkeyPressed с id действия

struct KeqdroidHotkeySpec {
  std::string action;
  UINT modifiers = 0;    // MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN.
  UINT virtual_key = 0;  // VK_* code.
};

// возвращает действия, которые не встали: сочетание занято другим приложением
std::vector<std::string> KeqdroidApplyHotkeys(
    HWND hwnd, const std::vector<KeqdroidHotkeySpec>& specs);

std::string KeqdroidHotkeyActionForId(int hotkey_id);

void KeqdroidUnregisterAllHotkeys(HWND hwnd);

#endif  // RUNNER_WINDOWS_HOTKEYS_H_
