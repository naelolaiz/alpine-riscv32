# Steps

These guides are steps 7 to 11, and the CI part of step 23, of the 24-step
[plan](https://github.com/naelolaiz/esp32s31-alpine/blob/main/docs/plan.md)
of [esp32s31-alpine](https://github.com/naelolaiz/esp32s31-alpine), which
runs this port on an ESP32-S31 board. Steps 7 to 11 need no board, so they
live here, apart from the board work, and can go upstream to Alpine on their
own. The other steps, and the journal entries for all of them, are in
esp32s31-alpine ([step list](https://github.com/naelolaiz/esp32s31-alpine/blob/main/docs/steps/README.md)).

| Step | What | Guide |
| --- | --- | --- |
| 7 | Build environment and aports edits | [07-build-environment.md](07-build-environment.md), [07-aports-edits.md](07-aports-edits.md) |
| 8 | Cross toolchain | [08-cross-toolchain.md](08-cross-toolchain.md) |
| 9 | Base system | [09-base-system.md](09-base-system.md) |
| 10 | Full-system QEMU | [10-qemu-system.md](10-qemu-system.md) |
| 11 | Native builds in a riscv32 container | [11-native-build.md](11-native-build.md) |
| 23 (part 1) | Package builds on GitHub Actions | [23-package-ci.md](23-package-ci.md) |
