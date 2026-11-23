#!/bin/sh
# Rebuilds the lock-notify helper (needs gcc and wayland-scanner).
set -e
cd "$(dirname "$0")"
wayland-scanner client-header hyprland-lock-notify-v1.xml lock-notify-proto.h
wayland-scanner private-code hyprland-lock-notify-v1.xml lock-notify-proto.c
gcc -O2 -o lock-notify lock-notify.c lock-notify-proto.c $(pkg-config --cflags --libs wayland-client)
