/*
 * idevice_shim.c — see idevice_shim.h for status and caveats.
 *
 * ============================================================================================
 * STATUS: NOT COMPILED BY DEFAULT. NOT VERIFIED. NOT LINKABLE AS-IS.
 * ============================================================================================
 * This translation unit is never built by Ghosted.xcodeproj (the `IDEVICE_FFI_ENABLED` flag is
 * off and the file is not in any target's Compile Sources phase). It was written on Linux against
 * the documented libimobiledevice API and has NEVER been compiled or linked. Treat every
 * signature below as a claim to be checked against a real <libimobiledevice/*.h>, not as code
 * known to work.
 *
 * Note that `idevice.h` declares its own `idevice_error_t` and a thread-local `idevice_error`
 * that most calls set. This file wraps that into ghosted_last_error_message().
 */

#include "idevice_shim.h"

/*
 * Vendor headers. These are only present with libimobiledevice installed:
 *   brew install libimobiledevice libimobiledevice-glue
 * The include names below are the ones that ship with that formula; they have varied across
 * releases (notably `idevice.h` gained `<idevice/idevice.h>` style nesting in 1.3.0), so this is
 * the first thing to fix if the build fails.
 */
#include <idevice.h>
#include <idevice/libimobiledevice.h>

#include <stdlib.h>
#include <string.h>

/*
 * Handle layouts. These mirror the vendor's opaque structs by value. This is the fragile part of
 * any libimobiledevice binding: it depends on the vendor's struct having exactly these members in
 * this order. If a future release reorders or adds fields, this silently corrupts memory rather
 * than failing to compile.
 *
 * The alternative — include <idevice.h> here and pass its own types through — avoids the
 * duplication at the cost of leaking vendor headers into the Swift module map. Given this file is
 * compiled as C (not exposed to Swift directly), the duplication is the lesser evil: Swift only
 * ever sees the opaque GhostedDevice/GhostedHandle.
 */
struct GhostedDevice {
    idevice_t device;
};

struct GhostedHandle {
    idevice_t device;
    lockdown_t service;
    locationd_t location;
};

/*
 * Thread-local error text. libimobiledevice's own idevice_error_t is a global, not thread-local, on
 * some releases, so this cannot be made correct here alone — the Swift side must serialise its
 * calls (it does, via the IdeviceBackend actor) and must copy the message before its next call.
 */
static __thread char ghosted_error_buffer[512];

const char *ghosted_last_error_message(void) {
    idevice_error_t err = idevice_error_get();
    if (err == IDEVICE_SUCCESS) {
        ghosted_error_buffer[0] = '\0';
        return ghosted_error_buffer;
    }
    /*
     * idevice_error_get_str exists on newer libimobiledevice and returns NULL for unknown codes.
     * Older releases lack it entirely, which is why this is guarded rather than called directly.
     */
#if defined(IDEVICE_VERSION_MAJOR) && (IDEVICE_VERSION_MAJOR > 1 || \
    (IDEVICE_VERSION_MAJOR == 1 && IDEVICE_VERSION_MINOR >= 3))
    const char *message = idevice_error_get_str(err);
    if (message != NULL) {
        strncpy(ghosted_error_buffer, message, sizeof(ghosted_error_buffer) - 1);
        ghosted_error_buffer[sizeof(ghosted_error_buffer) - 1] = '\0';
        return ghosted_error_buffer;
    }
#endif
    snprintf(ghosted_error_buffer, sizeof(ghosted_error_buffer),
             "libimobiledevice error %d", (int)err);
    return ghosted_error_buffer;
}

int ghosted_device_connect(const char *udid, GhostedDevice **out) {
    if (out == NULL) {
        return -1;
    }
    *out = NULL;

    idevice_t device = NULL;
    idevice_error_t err = idevice_new(&device, udid);
    if (err != IDEVICE_SUCCESS || device == NULL) {
        return -1;
    }

    GhostedDevice *wrapper = calloc(1, sizeof(GhostedDevice));
    if (wrapper == NULL) {
        idevice_free(device);
        return -1;
    }
    wrapper->device = device;
    *out = wrapper;
    return 0;
}

void ghosted_device_disconnect(GhostedDevice *device) {
    if (device == NULL) {
        return;
    }
    if (device->device != NULL) {
        idevice_free(device->device);
    }
    free(device);
}

int ghosted_device_supports_developer_mode(GhostedDevice *device, int *enabled) {
    if (device == NULL || enabled == NULL || device->device == NULL) {
        return -1;
    }
    *enabled = 0;

    lockdown_t lockdown = NULL;
    idevice_error_t err = lockdownd_client_new_with_handshake(device->device, &lockdown, "Ghosted");
    if (err != IDEVICE_SUCCESS || lockdown == NULL) {
        return -1;
    }

    /*
     * Developer-services availability is reported as the "DeveloperModeStatus" service being
     * present. Absent means the device is paired but developer mode is off; a handshake failure
     * (handled above) means it is not paired at all. Keeping these distinct is the whole reason
     * this function returns an int rather than a bool.
     */
    int enabled_value = 0;
    err = lockdownd_get_value(NULL, lockdown, "DeveloperModeStatus", plist_to_str, &enabled_value);
    lockdownd_client_free(lockdown);

    if (err == IDEVICE_SUCCESS) {
        *enabled = enabled_value ? 1 : 0;
        return 0;
    }
    return -1;
}

int ghosted_device_install_pairing(GhostedDevice *device, const char *staging_path) {
    if (device == NULL || staging_path == NULL || device->device == NULL) {
        return -1;
    }
    return (int)mobileimage_mounter_copy_pairing_record(staging_path, NULL);
}

int ghosted_device_mount_ddi(GhostedDevice *device, const char *ddi_directory) {
    if (device == NULL || ddi_directory == NULL || device->device == NULL) {
        return -1;
    }

    mobileimage_mounter_t mounter = NULL;
    idevice_error_t err = mobileimage_mounter_client_new(device->device, &mounter);
    if (err != IDEVICE_SUCCESS || mounter == NULL) {
        return -1;
    }

    /*
     * lookup returns the device's image signature, which is part of the mount request: the device
     * refuses a DDI whose build does not match. Passing NULL for it is what most tools do and
     * works, but naming it here so the failure mode is documented rather than mysterious.
     */
    err = mobileimage_mounter_mount(mounter, NULL, ddi_directory, NULL, NULL);
    mobileimage_mounter_client_free(mounter);

    return (err == IDEVICE_SUCCESS) ? 0 : -1;
}

int ghosted_tunnel_open(GhostedDevice *device, GhostedHandle **out) {
    if (out == NULL) {
        return -1;
    }
    *out = NULL;

    if (device == NULL || device->device == NULL) {
        return -1;
    }

    locationd_t location = NULL;
    idevice_error_t err = locationd_client_new(device->device, &location);
    if (err != IDEVICE_SUCCESS || location == NULL) {
        return -1;
    }

    GhostedHandle *wrapper = calloc(1, sizeof(GhostedHandle));
    if (wrapper == NULL) {
        locationd_client_free(location);
        return -1;
    }
    wrapper->device = device->device;
    wrapper->location = location;
    wrapper->service = NULL;
    *out = wrapper;
    return 0;
}

int ghosted_tunnel_set_location(GhostedHandle *tunnel,
                                double latitude,
                                double longitude,
                                double horizontal_accuracy) {
    if (tunnel == NULL || tunnel->location == NULL) {
        return -1;
    }
    idevice_error_t err = locationd_set_location(tunnel->location, latitude, longitude,
                                                 horizontal_accuracy);
    return (err == IDEVICE_SUCCESS) ? 0 : -1;
}

int ghosted_tunnel_clear_location(GhostedHandle *tunnel) {
    /*
     * CoreLocation has no explicit "stop simulating"; the documented way to release the fake
     * position is to set it to zero, which the service reads as "stop". Negative accuracy marks it
     * as unknown, matching how the rest of the API expresses that.
     */
    return ghosted_tunnel_set_location(tunnel, 0.0, 0.0, -1.0);
}

int ghosted_tunnel_heartbeat(GhostedHandle *tunnel) {
    if (tunnel == NULL || tunnel->location == NULL) {
        return -1;
    }
    /*
     * locationd_start_location_simulation owns the connection and blocks until it fails, so this
     * does not return on success — the Swift caller runs it on a detached task and treats a return
     * as "the tunnel died". That inversion is deliberate and is mirrored in IdeviceBackend.swift.
     */
    idevice_error_t err = locationd_start_location_simulation(tunnel->location, 0.0, 0.0);
    return (err == IDEVICE_SUCCESS) ? 0 : -1;
}

void ghosted_tunnel_close(GhostedHandle *tunnel) {
    if (tunnel == NULL) {
        return;
    }
    if (tunnel->location != NULL) {
        locationd_client_free(tunnel->location);
    }
    if (tunnel->service != NULL) {
        lockdownd_client_free(tunnel->service);
    }
    free(tunnel);
}