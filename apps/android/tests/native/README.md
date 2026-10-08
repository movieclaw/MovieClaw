# Android native lifecycle regression tests

Run from any directory:

```sh
apps/android/tests/native/run.sh
```

Requires Linux, Bash, and GCC/g++ with C++17, pthreads, AddressSanitizer and
UndefinedBehaviorSanitizer (`CXX` can override the compiler). No Android SDK,
JVM or prebuilt libmpv is needed. Builds use a temporary directory and are removed
on exit.

The tests compile the production JNI bridge sources. Stub JNI objects model
Surface references; libmpv callbacks model a blocking event consumer. ISO tests
replace UDF parsing with an in-memory volume that asserts no open file survives
volume destruction. All accept/connection/prefetch workers, POSIX socket IO and
teardown paths are production code, with a loopback HTTP server that intentionally
parks Range reads until shutdown.

- MPV: 200 repeated dual-instance lifecycles, Surface replacement/detach failure,
  blocked event-loop destruction, FILE_LOADED generation, failed-create cleanup,
  and failed commands.
- ISO: 60 cycles closing while blocked in remote body reads or local request
  headers; each close must complete within two seconds. Also checks consecutive
  open, duplicate close, unsupported HTTPS rejection, freed prefetch buffers,
  30 blocked-send worker cycles, and no leaked file descriptors.

These tests verify ownership and teardown, not real libmpv video rendering, UDF
image parsing or Android Surface behavior. Device playback checks remain needed.
