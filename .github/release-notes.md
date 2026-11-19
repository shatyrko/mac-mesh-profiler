Native macOS app to install, run and configure the **Yggdrasil** and **Mycelium** mesh network daemons, each independently.

## Download

`MacMeshProfiler-{{VERSION}}-macOS.zip` — universal (Apple Silicon + Intel), macOS 14 or later.

```
sha256  {{SHA256}}
```

## Install

1. Unzip and move **Mac Mesh Profiler.app** to `/Applications`.
2. The app is ad-hoc signed, not notarized, so macOS blocks it on first launch. Either
   - open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - remove the quarantine flag:
     ```bash
     xattr -dr com.apple.quarantine "/Applications/Mac Mesh Profiler.app"
     ```
3. Actions that change system state (install, start/stop, writing configs) ask for an administrator password.

See the [README](https://github.com/shatyrko/mac-mesh-profiler#readme) for what the app changes on your system.
