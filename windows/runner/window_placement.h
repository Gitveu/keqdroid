#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>

// границы окна в HKCU, чтобы открываться там же, и при автозапуске тоже.

// окно должно быть ещё скрыто
bool KeqdroidRestoreWindowPlacement(HWND hwnd, bool* out_maximized);

void KeqdroidSaveWindowPlacement(HWND hwnd);

#endif  // RUNNER_WINDOW_PLACEMENT_H_
