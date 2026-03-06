#!/bin/sh
# firefox-wayland.sh - Enable Firefox Wayland native rendering
# Location: /etc/profile.d/firefox-wayland.sh
#
# This enables native Wayland support in Firefox instead of XWayland.
# Benefits: Better performance, proper DPI scaling, no X11 overhead.

export MOZ_ENABLE_WAYLAND=1
