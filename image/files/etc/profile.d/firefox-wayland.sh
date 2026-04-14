#!/bin/sh
# firefox-wayland.sh - Enable Firefox Wayland native rendering
# Location: /etc/profile.d/firefox-wayland.sh
#
# This enables native Wayland support in Firefox instead of XWayland.
# Benefits: Better performance, proper DPI scaling, no X11 overhead.

export MOZ_ENABLE_WAYLAND=1
# Point Firefox at the Intel iGPU render node for VA-API hardware video decode.
# On hybrid laptops renderD128 is the iGPU; without this, Firefox may pick the
# dGPU which doesn't support VA-API, falling back to software decode (~400% more CPU).
export MOZ_DRM_DEVICE=/dev/dri/renderD128
