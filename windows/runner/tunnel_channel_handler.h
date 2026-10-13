#ifndef RUNNER_TUNNEL_CHANNEL_HANDLER_H_
#define RUNNER_TUNNEL_CHANNEL_HANDLER_H_

#include <flutter/flutter_engine.h>

#include <string>

void RegisterKeqdisTunnelChannel(flutter::FlutterEngine* engine);

// второй экземпляр с --autostart пересылает подключение
void KeqdisRequestAutostartConnect();

// до движка, Dart заберёт через getPendingDeepLink
void KeqdisSetPendingDeepLink(const std::string& url);

void KeqdisRequestDeepLink(const std::string& url);

void KeqdisNotifyHotkeyPressed(const std::string& action);

// Dart по нему ставит на паузу анимацию и опрос трафика: жизненный цикл Flutter отдаёт SW_HIDE как inactive, не hidden
void KeqdisNotifyWindowVisibility(bool visible);

// чтобы после перезагрузки интернет был до запуска keqdroid
void KeqdisClearSystemProxyOnSessionEnd();

#endif  // RUNNER_TUNNEL_CHANNEL_HANDLER_H_
