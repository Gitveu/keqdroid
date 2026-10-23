#ifndef RUNNER_WINDOWS_TRAY_H_
#define RUNNER_WINDOWS_TRAY_H_

#include <windows.h>

// иконку трея и меню держит tray_manager в Dart (lib/services/windows_tray_menu.dart), здесь только окно
void WindowsTrayInit(HWND hwnd);
void WindowsTrayDispose(HWND hwnd);
void WindowsTraySetMinimizeToTray(bool enabled);
bool WindowsTrayGetMinimizeToTray();
HWND WindowsTrayGetMainHwnd();
bool WindowsTrayActivateMainWindow();
// автозапуск в трей: окно ни разу не показывали, и разворот из сохранённых границ ждёт первого показа
void WindowsTrayStartHidden(int first_show_command);
bool WindowsTrayIsHiddenInTray();
bool WindowsTrayRestoreMainWindow();
bool WindowsTrayToggleMainWindow();
void WindowsTrayExitApplication(HWND hwnd);
bool WindowsTrayHandleMessage(HWND hwnd,
                              UINT message,
                              WPARAM wparam,
                              LPARAM lparam,
                              LRESULT* result);

#endif  // RUNNER_WINDOWS_TRAY_H_
