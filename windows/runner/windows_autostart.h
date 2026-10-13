#ifndef RUNNER_WINDOWS_AUTOSTART_H_
#define RUNNER_WINDOWS_AUTOSTART_H_

// обычный автозапуск через HKCU Run стартует без прав, и для TUN пришлось бы жать UAC после каждого входа.
// задача планировщика с HighestAvailable стартует с правами, платится одним UAC при создании. оба вида разом не включаются

// allow_elevation снят на старте приложения. false: задачу не создали или не удалили, ключ Run уже выставлен
bool KeqdroidApplyAutostart(bool enabled, bool elevated, bool allow_elevation);

// перенесли папку, и задача на старый путь уже не автозапуск
bool KeqdroidIsAutostartElevated();

bool KeqdroidIsAutostartEnabled();

#endif  // RUNNER_WINDOWS_AUTOSTART_H_
