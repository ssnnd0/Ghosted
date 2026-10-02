/*
 * idevice_shim.h — C shim over libimobiledevice / libimobiledevice-glue.
 *
 * ============================================================================================
 * STATUS: NOT COMPILED BY DEFAULT. NOT VERIFIED. NOT LINKABLE AS-IS.
 * ============================================================================================
 *
 * This header exists so the shape of the native bridge is written down and reviewable, and so the
 * Swift side has something real to bind to. It is gated behind the `IDEVICE_FFI_ENABLED` Swift
 * compilation condition, which is OFF, and nothing in Ghosted.xcodeproj compiles this file or
 * links the vendor libraries. Building it requires a Mac with Xcode and:
 *
 *     brew install libimobiledevice libimobiledevice-glue
 *
 * then the linker flags documented in XCODE.md. NONE of that has been done here: the work above
 * was done on Linux, which has neither the vendor libraries nor an iOS SDK. Expect to fix the
 * signatures below against the real <libimobiledevice/*.h> before trusting them — libimobiledevice
 * is not a stable C ABI and its enums and function signatures move between releases.
 *
 * WHAT THIS SHIM IS FOR
 *   It is deliberately the *smallest* surface that can drive a real location-simulation session:
 *   connect, verify a pairing record, mount the DDI, open the tunnel, push one coordinate, heartbeat.
 *   Anything else (device listing, backup, afc) is deliberately absent — an FFI layer nobody has
 *   run is worse than a small one that is entirely accounted for.
 *
 * EVERY FUNCTION HERE HAS A DOCUMENTED FAILURE MODE. None of them may return a value the caller
 * treats as success unless the return is explicitly 0.
 */

#ifndef GHOSTED_IDEVICE_SHIM_H
#define GHOSTED_IDEVICE_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Opaque handles. Opaque rather than mirroring the vendor structs so a signature change in
 * libimobiledevice cannot corrupt memory through this header.
 */
typedef struct GhostedDevice GhostedDevice;
typedef struct GhostedHandle GhostedHandle;

/*
 * Last error for the calling thread. libimobiledevice reports most failures through a
 * thread-local `idevice_error_t` rather than a return value, so without this the Swift side
 * could not tell "device busy" from "no such device".
 * Returns a static, thread-local, NUL-terminated string. Never NULL. Valid until the next
 * libimobiledevice call on the same thread — copy it before doing anything else.
 */
const char *ghosted_last_error_message(void);

/*
 * Connect to the device at `udid` (NULL = the single attached device).
 *
 * Returns 0 on success. On failure returns non-zero and leaves *out unmodified; *out is set to
 * NULL on entry so a caller that ignores the return value still cannot deref a stale pointer.
 *
 * NOTE: libimobiledevice is not thread-safe per-device without external locking. The Swift side
 * serialises all calls through the IdeviceBackend actor, so this shim adds no locking of its own.
 */
int ghosted_device_connect(const char *udid, GhostedDevice **out);

/* Release a device handle. Safe to call with NULL. */
void ghosted_device_disconnect(GhostedDevice *device);

/*
 * Whether the device records developer mode / the mounted DDI such that location simulation can
 * start.
 *
 * Returns 0 and writes 0/1 to *enabled on success. Returns non-zero if the device does not
 * support developer services at all (an unpaired or non-iOS target), which is a different
 * condition from "developer mode is off" — the caller must not conflate them.
 */
int ghosted_device_supports_developer_mode(GhostedDevice *device, int *enabled);

/*
 * Install pairing records at `staging_path` (the app's Documents/DDI staging folder) into this
 * device's usbmuxd.
 *
 * Returns 0 on success. Pairing writes to a global, device-independent store on macOS, so this
 * cannot be rolled back by ghosted_device_disconnect — see the note in IdeviceBackend.swift.
 */
int ghosted_device_install_pairing(GhostedDevice *device, const char *staging_path);

/*
 * Mount the Developer Disk Image found at `ddi_directory` on the device.
 *
 * Returns 0 on success. libimobiledevice requires the device be on USB (not Wi-Fi) for a mount,
 * and the DDI must match the device's iOS build exactly; both failures surface here.
 */
int ghosted_device_mount_ddi(GhostedDevice *device, const char *ddi_directory);

/*
 * Open the location-simulation (CoreLocation "tunnel") channel.
 *
 * Returns 0 on success. The handle owns the connection; ghosted_tunnel_close must be called to
 * release it, and pushing a coordinate on a closed handle returns non-zero rather than crashing.
 */
int ghosted_tunnel_open(GhostedDevice *device, GhostedHandle **out);

/*
 * Push one simulated position.
 *
 * `latitude`/`longitude` are decimal degrees. `horizontal_accuracy` is metres; a negative value
 * is how CoreLocation expresses "unknown", and is forwarded verbatim.
 *
 * Returns 0 on success. The vendor call blocks on the tunnel's write buffer, so this is expected
 * to be called from a background context and never from the main thread.
 */
int ghosted_tunnel_set_location(GhostedHandle *tunnel,
                                double latitude,
                                double longitude,
                                double horizontal_accuracy);

/* Clear the simulated position, restoring real GPS. Returns 0 on success. */
int ghosted_tunnel_clear_location(GhostedHandle *tunnel);

/*
 * Keep the tunnel alive. Returns 0 on success. libimobiledevice's heartbeat is itself
 * thread-blocking, so the Swift side runs this on a dedicated detached task rather than inline.
 */
int ghosted_tunnel_heartbeat(GhostedHandle *tunnel);

/* Release a tunnel handle. Safe to call with NULL. */
void ghosted_tunnel_close(GhostedHandle *tunnel);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTED_IDEVICE_SHIM_H */