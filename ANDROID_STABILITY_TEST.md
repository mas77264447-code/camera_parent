# Android Stability Test

Checklist:

- Lock screen: verify foreground service remains active.
- Disable network: verify recovery starts.
- Enable network: verify reconnect.
- Reboot device: verify BootReceiver starts service.
- Check battery optimization state.
- Test Doze mode.

Expected flow:

Boot -> Service -> FlutterEngine -> Agent -> Recovery -> WebRTC
