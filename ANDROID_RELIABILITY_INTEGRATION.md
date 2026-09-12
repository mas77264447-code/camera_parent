# Android Reliability Integration

This build adds the reliability integration layer.

Flow:

BOOT_COMPLETED
 -> BootReceiver
 -> Foreground Service
 -> AndroidReliabilityMonitor
 -> AgentService
 -> StabilityController
 -> StreamManager recovery

Components:
- AndroidReliabilityMonitor: device/service health checks
- StabilityController: coordinates recovery
- RecoveryQueue: prevents overlapping recovery operations
- NetworkMonitor: network changes
- StreamWatchdog: stream health checks

Next validation:
1. Build and install.
2. Test reboot.
3. Test network loss/restore.
4. Check Logcat recovery events.
