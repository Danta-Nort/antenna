// SPDX-License-Identifier: AGPL-3.0-only
// Image data on the clipboard for the window's composer, over `antenna/clipboard` (clipboard_channel.cc).
#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Listen on `antenna/clipboard` for the life of [registry] (the FlView).
void clipboard_channel_register(FlPluginRegistry* registry);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
