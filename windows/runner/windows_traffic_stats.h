#ifndef RUNNER_WINDOWS_TRAFFIC_STATS_H_
#define RUNNER_WINDOWS_TRAFFIC_STATS_H_

#include <cstdint>

// tun считает только виртуальные адаптеры, proxy только loopback
bool ReadSessionTrafficCounters(const char* mode,
                                uint64_t* in_octets,
                                uint64_t* out_octets);

#endif  // RUNNER_WINDOWS_TRAFFIC_STATS_H_
