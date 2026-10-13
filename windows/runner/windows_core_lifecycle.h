#ifndef RUNNER_WINDOWS_CORE_LIFECYCLE_H_
#define RUNNER_WINDOWS_CORE_LIFECYCLE_H_

#include <windows.h>

// job object и реестр pid: ядра умирают вместе с приложением, даже при падении
void KeqdisInitCoreProcessGuard();
void KeqdisAttachCoreProcess(DWORD pid);
void KeqdisRegisterSessionCoreProcesses(DWORD xray_pid, DWORD singbox_pid);
void KeqdisClearSessionCoreProcesses();

#endif  // RUNNER_WINDOWS_CORE_LIFECYCLE_H_
