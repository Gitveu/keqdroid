#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

// до перезапуска с правами, чтобы новый процесс сразу взял мьютекс
void RunnerReleaseSingleInstanceMutex();

#endif  // RUNNER_SINGLE_INSTANCE_H_
