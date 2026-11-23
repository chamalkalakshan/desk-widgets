// Prints "locked" / "unlocked" (one per line) when Hyprland's session lock changes.
// Used by ../Pet.qml. Build: see build.sh
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <wayland-client.h>
#include "lock-notify-proto.h"

static struct hyprland_lock_notifier_v1 *notifier;

static void on_locked(void *d, struct hyprland_lock_notification_v1 *n) { puts("locked"); fflush(stdout); }
static void on_unlocked(void *d, struct hyprland_lock_notification_v1 *n) { puts("unlocked"); fflush(stdout); }
static const struct hyprland_lock_notification_v1_listener lock_listener = { on_locked, on_unlocked };

static void on_global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t ver) {
    if (!strcmp(iface, hyprland_lock_notifier_v1_interface.name))
        notifier = wl_registry_bind(reg, name, &hyprland_lock_notifier_v1_interface, 1);
}
static void on_global_remove(void *d, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener reg_listener = { on_global, on_global_remove };

int main(void) {
    prctl(PR_SET_PDEATHSIG, SIGTERM);   // go away with the widget process
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fputs("lock-notify: no Wayland display\n", stderr); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!notifier) { fputs("lock-notify: compositor has no hyprland_lock_notifier_v1\n", stderr); return 2; }
    struct hyprland_lock_notification_v1 *n = hyprland_lock_notifier_v1_get_lock_notification(notifier);
    hyprland_lock_notification_v1_add_listener(n, &lock_listener, NULL);
    while (wl_display_dispatch(dpy) != -1) {}
    return 0;
}
