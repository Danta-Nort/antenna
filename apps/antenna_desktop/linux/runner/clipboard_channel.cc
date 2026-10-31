// SPDX-License-Identifier: AGPL-3.0-only
// Image data on the clipboard for the composer's paste (lib/host/paste.dart, ClipboardImages), over
// `antenna/clipboard`: `image` → PNG bytes, or null when the clipboard holds no image. Flutter's clipboard API is text
// only. GTK turns whatever image type the clipboard owner offers (image/png, image/jpeg, image/bmp…) into a pixbuf,
// which is encoded as PNG here.

#include "clipboard_channel.h"

#include <gtk/gtk.h>

// The clipboard owner answered (another process, so asynchronously): reply to the window's call.
static void image_received(GtkClipboard* clipboard, GdkPixbuf* pixbuf, gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  if (pixbuf == nullptr) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  gchar* buffer = nullptr;
  gsize size = 0;
  g_autoptr(GError) error = nullptr;
  if (!gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size, "png", &error, nullptr)) {
    fl_method_call_respond_error(call, "encode_failed", error != nullptr ? error->message : "png", nullptr, nullptr);
    return;
  }
  g_autoptr(FlValue) bytes = fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buffer), size);
  g_free(buffer);
  fl_method_call_respond_success(call, bytes, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(call), "image") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  GtkClipboard* clipboard = gtk_clipboard_get_default(gdk_display_get_default());
  // Not gtk_clipboard_wait_for_image: it would spin a nested main loop inside a platform message.
  gtk_clipboard_request_image(clipboard, image_received, g_object_ref(call));
}

void clipboard_channel_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar = fl_plugin_registry_get_registrar_for_plugin(registry, "AntennaClipboard");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "antenna/clipboard",
                                                   FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr, nullptr);
  // The channel lives as long as the view.
  g_object_set_data_full(G_OBJECT(registry), "antenna-clipboard-channel", channel, g_object_unref);
}
