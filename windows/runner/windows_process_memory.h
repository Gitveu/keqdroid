#ifndef RUNNER_WINDOWS_PROCESS_MEMORY_H_
#define RUNNER_WINDOWS_PROCESS_MEMORY_H_

#include <cstdint>

// private_bytes это commit: его Windows считает занятым и его называет событие 2004.
// рабочий набор после сна бывает много меньше, страницы уходят в подкачку
struct ProcessResources {
  bool ok = false;
  uint64_t private_bytes = 0;
  uint64_t working_set = 0;
  uint64_t peak_working_set = 0;
  uint32_t handles = 0;
  uint32_t threads = 0;
  uint32_t gdi_objects = 0;
  uint32_t user_objects = 0;
};

// pid 0 это сам keqdroid.exe
ProcessResources QueryProcessResources(uint32_t pid);

#endif  // RUNNER_WINDOWS_PROCESS_MEMORY_H_
