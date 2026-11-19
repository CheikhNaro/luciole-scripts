extern "C" {
#include "xdg-shell-client-protocol.h"
}

#include <cairo/cairo.h>
#include <fcntl.h>
#include <pango/pangocairo.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace {

  struct Color {
    double r = 0.0;
    double g = 0.0;
    double b = 0.0;
    double a = 1.0;
  };

  Color parseHexColor(std::string_view hex, double defaultAlpha = 1.0) {
    if (hex.empty()) {
      return {0, 0, 0, defaultAlpha};
    }
    if (hex.front() == '#') {
      hex.remove_prefix(1);
    }
    if (hex.size() == 6) {
      unsigned int val = 0;
      std::stringstream ss;
      ss << std::hex << hex;
      ss >> val;
      return {
          ((val >> 16) & 0xFF) / 255.0,
          ((val >> 8) & 0xFF) / 255.0,
          (val & 0xFF) / 255.0,
          defaultAlpha,
      };
    }
    if (hex.size() == 8) {
      unsigned int val = 0;
      std::stringstream ss;
      ss << std::hex << hex;
      ss >> val;
      return {
          ((val >> 24) & 0xFF) / 255.0,
          ((val >> 16) & 0xFF) / 255.0,
          ((val >> 8) & 0xFF) / 255.0,
          (val & 0xFF) / 255.0,
      };
    }
    return {0, 0, 0, defaultAlpha};
  }

  struct NoctaliaPalette {
    Color surface = parseHexColor("#131413");
    Color onSurface = parseHexColor("#e4e2e0");
    Color onSurfaceVariant = parseHexColor("#c2c8c3");
    Color primary = parseHexColor("#b7cbbe");
    Color surfaceContainer = parseHexColor("#1f201f");
    Color surfaceContainerHigh = parseHexColor("#292a29");
    Color outlineVariant = parseHexColor("#424844");
    Color hover = parseHexColor("#292a29");
  };

  NoctaliaPalette loadPalette() {
    NoctaliaPalette palette;
    const char* xdgConfig = std::getenv("XDG_CONFIG_HOME");
    std::string configPath;
    if (xdgConfig && *xdgConfig) {
      configPath = std::string(xdgConfig) + "/luciole/colors.toml";
    } else {
      const char* home = std::getenv("HOME");
      if (home) {
        configPath = std::string(home) + "/.config/luciole/colors.toml";
      }
    }

    if (configPath.empty()) {
      return palette;
    }

    std::ifstream file(configPath);
    if (!file.is_open()) {
      return palette;
    }

    std::string line;
    while (std::getline(file, line)) {
      auto eqPos = line.find('=');
      if (eqPos == std::string::npos) {
        continue;
      }
      std::string key = line.substr(0, eqPos);
      std::string val = line.substr(eqPos + 1);

      auto trim = [](std::string& s) {
        s.erase(0, s.find_first_not_of(" \t\r\n\""));
        s.erase(s.find_last_not_of(" \t\r\n\"") + 1);
      };
      trim(key);
      trim(val);

      if (key == "surface") palette.surface = parseHexColor(val);
      else if (key == "on_surface") palette.onSurface = parseHexColor(val);
      else if (key == "on_surface_variant") palette.onSurfaceVariant = parseHexColor(val);
      else if (key == "primary") palette.primary = parseHexColor(val);
      else if (key == "surface_container") palette.surfaceContainer = parseHexColor(val);
      else if (key == "surface_container_high") palette.surfaceContainerHigh = parseHexColor(val);
      else if (key == "outline_variant") palette.outlineVariant = parseHexColor(val);
      else if (key == "hover") palette.hover = parseHexColor(val);
    }
    return palette;
  }

  struct Item {
    std::string name;
    std::string detail;
    std::string value;
  };

  Item parseItemLine(std::string_view line) {
    std::vector<std::string_view> parts;
    std::size_t start = 0;
    while (start <= line.size()) {
      auto pos = line.find('\t', start);
      if (pos == std::string_view::npos) {
        parts.push_back(line.substr(start));
        break;
      }
      parts.push_back(line.substr(start, pos - start));
      start = pos + 1;
    }

    Item item;
    if (parts.size() == 1) {
      item.name = std::string(parts[0]);
      item.value = item.name;
    } else if (parts.size() == 2) {
      item.name = std::string(parts[0]);
      item.value = std::string(parts[1]);
    } else if (parts.size() >= 3) {
      item.name = std::string(parts[0]);
      item.detail = std::string(parts[1]);
      item.value = std::string(parts[2]);
    }
    return item;
  }

  bool containsCaseInsensitive(std::string_view text, std::string_view query) {
    if (query.empty()) return true;
    auto it = std::search(
        text.begin(), text.end(), query.begin(), query.end(),
        [](char a, char b) { return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b)); }
    );
    return it != text.end();
  }

  // Wayland state
  struct Buffer {
    wl_buffer* buffer = nullptr;
    void* shm_data = nullptr;
    int size = 0;
    bool busy = false;
  };

  struct AppState {
    wl_display* display = nullptr;
    wl_registry* registry = nullptr;
    wl_compositor* compositor = nullptr;
    wl_shm* shm = nullptr;
    xdg_wm_base* wm_base = nullptr;
    wl_seat* seat = nullptr;
    wl_keyboard* keyboard = nullptr;
    wl_pointer* pointer = nullptr;

    wl_surface* surface = nullptr;
    struct xdg_surface* xdg_surf = nullptr;
    struct xdg_toplevel* toplevel = nullptr;

    Buffer buffers[2];
    int current_buffer = 0;

    xkb_context* xkb_ctx = nullptr;
    xkb_keymap* xkb_map = nullptr;
    xkb_state* xkb_st = nullptr;

    int width = 450;
    int height = 490;
    bool configured = false;
    bool running = true;
    int exit_code = 1;
    std::string selected_value;

    std::string title = "Luciole";
    std::string search_query;
    std::vector<Item> all_items;
    std::vector<int> filtered_indices;
    int selected_idx = 0;
    int scroll_offset = 0;
    int hovered_idx = -1;

    NoctaliaPalette palette;
  };

  void updateFilter(AppState& app) {
    app.filtered_indices.clear();
    for (int i = 0; i < static_cast<int>(app.all_items.size()); ++i) {
      if (containsCaseInsensitive(app.all_items[i].name, app.search_query) ||
          containsCaseInsensitive(app.all_items[i].detail, app.search_query)) {
        app.filtered_indices.push_back(i);
      }
    }
    if (app.selected_idx >= static_cast<int>(app.filtered_indices.size())) {
      app.selected_idx = std::max(0, static_cast<int>(app.filtered_indices.size()) - 1);
    }
    app.scroll_offset = std::clamp(app.scroll_offset, 0, std::max(0, static_cast<int>(app.filtered_indices.size()) - 10));
  }

  void drawRoundedRect(cairo_t* cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
    cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
  }

  void setCairoColor(cairo_t* cr, const Color& c) {
    cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a);
  }

  void redraw(AppState& app);

  static void buffer_release(void* data, wl_buffer* /*wl_buffer*/) {
    auto* buf = static_cast<Buffer*>(data);
    buf->busy = false;
  }

  static const wl_buffer_listener buffer_listener = {
      buffer_release,
  };

  Buffer* getBuffer(AppState& app) {
    app.current_buffer = 1 - app.current_buffer;
    Buffer& buf = app.buffers[app.current_buffer];
    int stride = app.width * 4;
    int size = stride * app.height;

    if (!buf.buffer || buf.size != size) {
      if (buf.buffer) {
        wl_buffer_destroy(buf.buffer);
        munmap(buf.shm_data, buf.size);
      }
      int fd = memfd_create("luciole-dialog-shm", MFD_CLOEXEC);
      if (fd < 0 || ftruncate(fd, size) < 0) {
        if (fd >= 0) close(fd);
        return nullptr;
      }
      buf.shm_data = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
      buf.size = size;
      wl_shm_pool* pool = wl_shm_create_pool(app.shm, fd, size);
      buf.buffer = wl_shm_pool_create_buffer(pool, 0, app.width, app.height, stride, WL_SHM_FORMAT_ARGB8888);
      wl_buffer_add_listener(buf.buffer, &buffer_listener, &buf);
      wl_shm_pool_destroy(pool);
      close(fd);
    }
    return &buf;
  }

  void redraw(AppState& app) {
    Buffer* buf = getBuffer(app);
    if (!buf) return;

    cairo_surface_t* surface = cairo_image_surface_create_for_data(
        static_cast<unsigned char*>(buf->shm_data), CAIRO_FORMAT_ARGB32, app.width, app.height, app.width * 4
    );
    cairo_t* cr = cairo_create(surface);

    // 1. Background
    setCairoColor(cr, app.palette.surface);
    cairo_paint(cr);

    // 2. Window border
    setCairoColor(cr, app.palette.outlineVariant);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, app.width - 1.0, app.height - 1.0);
    cairo_stroke(cr);

    // 3. Header: Title (NO CLOSE BUTTON per user instruction)
    PangoLayout* layout = pango_cairo_create_layout(cr);
    PangoFontDescription* fontDesc = pango_font_description_new();
    pango_font_description_set_family(fontDesc, "Sans");
    pango_font_description_set_size(fontDesc, 14 * PANGO_SCALE);
    pango_font_description_set_weight(fontDesc, PANGO_WEIGHT_BOLD);
    pango_layout_set_font_description(layout, fontDesc);

    // Category folder icon representation (small rounded indicator + text)
    setCairoColor(cr, app.palette.primary);
    drawRoundedRect(cr, 16, 16, 16, 14, 3);
    cairo_fill(cr);

    pango_layout_set_text(layout, app.title.c_str(), -1);
    cairo_move_to(cr, 40, 14);
    pango_cairo_show_layout(cr, layout);

    // Header separator line
    setCairoColor(cr, app.palette.outlineVariant);
    cairo_move_to(cr, 0, 46.5);
    cairo_line_to(cr, app.width, 46.5);
    cairo_stroke(cr);

    // 4. Search input box
    double inputX = 14;
    double inputY = 56;
    double inputW = app.width - 28;
    double inputH = 34;

    setCairoColor(cr, app.palette.surfaceContainer);
    drawRoundedRect(cr, inputX, inputY, inputW, inputH, 6);
    cairo_fill(cr);

    setCairoColor(cr, app.palette.outlineVariant);
    cairo_set_line_width(cr, 1.0);
    drawRoundedRect(cr, inputX + 0.5, inputY + 0.5, inputW - 1.0, inputH - 1.0, 6);
    cairo_stroke(cr);

    // Search input text or placeholder
    pango_font_description_set_size(fontDesc, 11 * PANGO_SCALE);
    pango_font_description_set_weight(fontDesc, PANGO_WEIGHT_NORMAL);
    pango_layout_set_font_description(layout, fontDesc);

    if (app.search_query.empty()) {
      setCairoColor(cr, app.palette.onSurfaceVariant);
      pango_layout_set_text(layout, "Filtrer...", -1);
    } else {
      setCairoColor(cr, app.palette.onSurface);
      pango_layout_set_text(layout, app.search_query.c_str(), -1);
    }
    cairo_move_to(cr, inputX + 10, inputY + 8);
    pango_cairo_show_layout(cr, layout);

    // Blinking or static cursor
    if (!app.search_query.empty()) {
      int textW = 0, textH = 0;
      pango_layout_get_pixel_size(layout, &textW, &textH);
      setCairoColor(cr, app.palette.primary);
      cairo_rectangle(cr, inputX + 10 + textW + 1, inputY + 8, 1.5, 16);
      cairo_fill(cr);
    }

    // 5. Items list
    double listY = 98;
    double itemH = 36;
    int visibleCount = (app.height - 100) / static_cast<int>(itemH);

    int total = static_cast<int>(app.filtered_indices.size());
    for (int v = 0; v < visibleCount; ++v) {
      int idx = app.scroll_offset + v;
      if (idx >= total) break;

      int realIdx = app.filtered_indices[idx];
      const auto& item = app.all_items[realIdx];
      double curY = listY + v * itemH;

      bool isSelected = (idx == app.selected_idx);
      bool isHovered = (idx == app.hovered_idx);

      if (isSelected) {
        setCairoColor(cr, app.palette.surfaceContainerHigh);
        drawRoundedRect(cr, inputX, curY, inputW, itemH - 4, 6);
        cairo_fill(cr);

        // Left accent bar on active row
        setCairoColor(cr, app.palette.primary);
        drawRoundedRect(cr, inputX + 2, curY + 4, 3, itemH - 12, 1.5);
        cairo_fill(cr);
      } else if (isHovered) {
        setCairoColor(cr, app.palette.hover);
        drawRoundedRect(cr, inputX, curY, inputW, itemH - 4, 6);
        cairo_fill(cr);
      }

      // Item Name
      if (isSelected) {
        setCairoColor(cr, app.palette.primary);
        pango_font_description_set_weight(fontDesc, PANGO_WEIGHT_BOLD);
      } else {
        setCairoColor(cr, app.palette.onSurface);
        pango_font_description_set_weight(fontDesc, PANGO_WEIGHT_NORMAL);
      }
      pango_layout_set_font_description(layout, fontDesc);
      pango_layout_set_text(layout, item.name.c_str(), -1);
      cairo_move_to(cr, inputX + 12, curY + 7);
      pango_cairo_show_layout(cr, layout);

      // Item Detail / Category badge
      if (!item.detail.empty()) {
        setCairoColor(cr, app.palette.onSurfaceVariant);
        pango_font_description_set_size(fontDesc, 9 * PANGO_SCALE);
        pango_font_description_set_weight(fontDesc, PANGO_WEIGHT_NORMAL);
        pango_layout_set_font_description(layout, fontDesc);
        pango_layout_set_text(layout, item.detail.c_str(), -1);
        int badgeW = 0, badgeH = 0;
        pango_layout_get_pixel_size(layout, &badgeW, &badgeH);
        cairo_move_to(cr, inputX + inputW - badgeW - 10, curY + 10);
        pango_cairo_show_layout(cr, layout);

        pango_font_description_set_size(fontDesc, 11 * PANGO_SCALE);
      }
    }

    pango_font_description_free(fontDesc);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);

    buf->busy = true;
    wl_surface_attach(app.surface, buf->buffer, 0, 0);
    wl_surface_damage(app.surface, 0, 0, app.width, app.height);
    wl_surface_commit(app.surface);
  }

  // Pointer callbacks
  static void pointer_enter(void*, wl_pointer*, uint32_t, wl_surface*, wl_fixed_t, wl_fixed_t) {}
  static void pointer_leave(void* data, wl_pointer*, uint32_t, wl_surface*) {
    auto* app = static_cast<AppState*>(data);
    app->hovered_idx = -1;
    if (app->configured) redraw(*app);
  }

  static void pointer_motion(void* data, wl_pointer*, uint32_t, wl_fixed_t, wl_fixed_t sy) {
    auto* app = static_cast<AppState*>(data);
    double y = wl_fixed_to_double(sy);
    if (y >= 98 && y < app->height) {
      int v = static_cast<int>((y - 98) / 36);
      int target = app->scroll_offset + v;
      if (target >= 0 && target < static_cast<int>(app->filtered_indices.size())) {
        if (app->hovered_idx != target) {
          app->hovered_idx = target;
          if (app->configured) redraw(*app);
        }
        return;
      }
    }
    if (app->hovered_idx != -1) {
      app->hovered_idx = -1;
      if (app->configured) redraw(*app);
    }
  }

  static void pointer_button(void* data, wl_pointer*, uint32_t, uint32_t, uint32_t button, uint32_t state) {
    auto* app = static_cast<AppState*>(data);
    if (button == 0x110 && state == WL_POINTER_BUTTON_STATE_PRESSED) { // Left click
      if (app->hovered_idx >= 0 && app->hovered_idx < static_cast<int>(app->filtered_indices.size())) {
        app->selected_idx = app->hovered_idx;
        int realIdx = app->filtered_indices[app->selected_idx];
        app->selected_value = app->all_items[realIdx].value;
        app->exit_code = 0;
        app->running = false;
      }
    }
  }

  static void pointer_axis(void* data, wl_pointer*, uint32_t, uint32_t axis, wl_fixed_t value) {
    auto* app = static_cast<AppState*>(data);
    if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) {
      double val = wl_fixed_to_double(value);
      if (val > 0) {
        app->scroll_offset = std::min(app->scroll_offset + 1, std::max(0, static_cast<int>(app->filtered_indices.size()) - 10));
      } else if (val < 0) {
        app->scroll_offset = std::max(0, app->scroll_offset - 1);
      }
      if (app->configured) redraw(*app);
    }
  }

  static void pointer_frame(void*, wl_pointer*) {}
  static void pointer_axis_source(void*, wl_pointer*, uint32_t) {}
  static void pointer_axis_stop(void*, wl_pointer*, uint32_t, uint32_t) {}
  static void pointer_axis_discrete(void*, wl_pointer*, uint32_t, int32_t) {}
  static void pointer_axis_value120(void*, wl_pointer*, uint32_t, int32_t) {}
  static void pointer_axis_relative_direction(void*, wl_pointer*, uint32_t, uint32_t) {}

  static const struct wl_pointer_listener pointer_listener = {
      .enter = pointer_enter,
      .leave = pointer_leave,
      .motion = pointer_motion,
      .button = pointer_button,
      .axis = pointer_axis,
      .frame = pointer_frame,
      .axis_source = pointer_axis_source,
      .axis_stop = pointer_axis_stop,
      .axis_discrete = pointer_axis_discrete,
      .axis_value120 = pointer_axis_value120,
      .axis_relative_direction = pointer_axis_relative_direction,
      .warp = nullptr,
  };

  // Keyboard callbacks
  static void keyboard_keymap(void* data, wl_keyboard*, uint32_t format, int fd, uint32_t size) {
    auto* app = static_cast<AppState*>(data);
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
      close(fd);
      return;
    }
    char* map_shm = static_cast<char*>(mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0));
    if (map_shm == MAP_FAILED) {
      close(fd);
      return;
    }
    app->xkb_map = xkb_keymap_new_from_string(app->xkb_ctx, map_shm, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map_shm, size);
    close(fd);
    app->xkb_st = xkb_state_new(app->xkb_map);
  }

  static void keyboard_enter(void*, wl_keyboard*, uint32_t, wl_surface*, wl_array*) {}
  static void keyboard_leave(void*, wl_keyboard*, uint32_t, wl_surface*) {}

  static void keyboard_key(void* data, wl_keyboard*, uint32_t, uint32_t, uint32_t key, uint32_t state) {
    auto* app = static_cast<AppState*>(data);
    if (state != WL_KEYBOARD_KEY_STATE_PRESSED) return;

    uint32_t sym = xkb_state_key_get_one_sym(app->xkb_st, key + 8);
    if (sym == XKB_KEY_Escape) {
      app->running = false;
      app->exit_code = 1;
      return;
    }

    if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
      if (!app->filtered_indices.empty() && app->selected_idx >= 0 && app->selected_idx < static_cast<int>(app->filtered_indices.size())) {
        int realIdx = app->filtered_indices[app->selected_idx];
        app->selected_value = app->all_items[realIdx].value;
        app->exit_code = 0;
        app->running = false;
      }
      return;
    }

    if (sym == XKB_KEY_Up) {
      if (app->selected_idx > 0) {
        app->selected_idx--;
        if (app->selected_idx < app->scroll_offset) {
          app->scroll_offset = app->selected_idx;
        }
        if (app->configured) redraw(*app);
      }
      return;
    }

    if (sym == XKB_KEY_Down) {
      if (app->selected_idx + 1 < static_cast<int>(app->filtered_indices.size())) {
        app->selected_idx++;
        int visibleCount = (app->height - 100) / 36;
        if (app->selected_idx >= app->scroll_offset + visibleCount) {
          app->scroll_offset = app->selected_idx - visibleCount + 1;
        }
        if (app->configured) redraw(*app);
      }
      return;
    }

    if (sym == XKB_KEY_BackSpace) {
      if (!app->search_query.empty()) {
        app->search_query.pop_back();
        updateFilter(*app);
        if (app->configured) redraw(*app);
      }
      return;
    }

    // Text typing for search
    char utf8[16] = {0};
    int len = xkb_state_key_get_utf8(app->xkb_st, key + 8, utf8, sizeof(utf8));
    if (len > 0 && utf8[0] >= 32) {
      app->search_query.append(utf8, len);
      updateFilter(*app);
      if (app->configured) redraw(*app);
    }
  }

  static void keyboard_modifiers(void* data, wl_keyboard*, uint32_t, uint32_t mods_depressed, uint32_t mods_latched, uint32_t mods_locked, uint32_t group) {
    auto* app = static_cast<AppState*>(data);
    if (app->xkb_st) {
      xkb_state_update_mask(app->xkb_st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
  }

  static void keyboard_repeat_info(void*, wl_keyboard*, int32_t, int32_t) {}

  static const struct wl_keyboard_listener keyboard_listener = {
      .keymap = keyboard_keymap,
      .enter = keyboard_enter,
      .leave = keyboard_leave,
      .key = keyboard_key,
      .modifiers = keyboard_modifiers,
      .repeat_info = keyboard_repeat_info,
  };

  // Seat
  static void seat_capabilities(void* data, wl_seat* seat, uint32_t caps) {
    auto* app = static_cast<AppState*>(data);
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !app->keyboard) {
      app->keyboard = wl_seat_get_keyboard(seat);
      wl_keyboard_add_listener(app->keyboard, &keyboard_listener, app);
    }
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !app->pointer) {
      app->pointer = wl_seat_get_pointer(seat);
      wl_pointer_add_listener(app->pointer, &pointer_listener, app);
    }
  }

  static void seat_name(void*, wl_seat*, const char*) {}

  static const struct wl_seat_listener seat_listener = {
      .capabilities = seat_capabilities,
      .name = seat_name,
  };

  // XDG surface
  static void xdg_surface_configure(void* data, struct xdg_surface* surface, uint32_t serial) {
    auto* app = static_cast<AppState*>(data);
    xdg_surface_ack_configure(surface, serial);
    app->configured = true;
    redraw(*app);
  }

  static const struct xdg_surface_listener xdg_surf_listener = {
      .configure = xdg_surface_configure,
  };

  static void xdg_toplevel_configure(void*, struct xdg_toplevel*, int32_t, int32_t, wl_array*) {}
  static void xdg_toplevel_close(void* data, struct xdg_toplevel*) {
    auto* app = static_cast<AppState*>(data);
    app->running = false;
    app->exit_code = 1;
  }

  static const struct xdg_toplevel_listener toplevel_listener = {
      .configure = xdg_toplevel_configure,
      .close = xdg_toplevel_close,
      .configure_bounds = nullptr,
      .wm_capabilities = nullptr,
  };

  // Registry
  static void registry_global(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t) {
    auto* app = static_cast<AppState*>(data);
    if (std::string_view(interface) == "wl_compositor") {
      app->compositor = static_cast<wl_compositor*>(wl_registry_bind(registry, name, &wl_compositor_interface, 4));
    } else if (std::string_view(interface) == "wl_shm") {
      app->shm = static_cast<wl_shm*>(wl_registry_bind(registry, name, &wl_shm_interface, 1));
    } else if (std::string_view(interface) == "xdg_wm_base") {
      app->wm_base = static_cast<xdg_wm_base*>(wl_registry_bind(registry, name, &xdg_wm_base_interface, 1));
      static const xdg_wm_base_listener wm_base_listener = {
          [](void*, xdg_wm_base* base, uint32_t serial) { xdg_wm_base_pong(base, serial); }
      };
      xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, nullptr);
    } else if (std::string_view(interface) == "wl_seat") {
      app->seat = static_cast<wl_seat*>(wl_registry_bind(registry, name, &wl_seat_interface, 5));
      wl_seat_add_listener(app->seat, &seat_listener, app);
    }
  }

  static void registry_global_remove(void*, wl_registry*, uint32_t) {}

  static const wl_registry_listener registry_listener = {
      registry_global,
      registry_global_remove,
  };

} // namespace

int main(int argc, char* argv[]) {
  AppState app;
  app.width = 450;
  app.height = 490;
  app.palette = loadPalette();

  bool readStdin = false;
  for (int i = 1; i < argc; ++i) {
    std::string_view arg = argv[i];
    if (arg == "--title" && i + 1 < argc) {
      app.title = argv[++i];
    } else if (arg == "--width" && i + 1 < argc) {
      app.width = std::atoi(argv[++i]);
    } else if (arg == "--height" && i + 1 < argc) {
      app.height = std::atoi(argv[++i]);
    } else if (arg == "--stdin") {
      readStdin = true;
    } else if (!arg.starts_with('-')) {
      app.all_items.push_back(parseItemLine(arg));
    }
  }

  if (app.all_items.empty() || readStdin) {
    std::string line;
    while (std::getline(std::cin, line)) {
      if (!line.empty()) {
        app.all_items.push_back(parseItemLine(line));
      }
    }
  }

  if (app.all_items.empty()) {
    std::cerr << "luciole-dialog: no items to display\n";
    return 1;
  }

  updateFilter(app);

  app.xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  app.display = wl_display_connect(nullptr);
  if (!app.display) {
    std::cerr << "luciole-dialog: cannot connect to Wayland display\n";
    return 1;
  }

  app.registry = wl_display_get_registry(app.display);
  wl_registry_add_listener(app.registry, &registry_listener, &app);
  wl_display_roundtrip(app.display);

  if (!app.compositor || !app.shm || !app.wm_base) {
    std::cerr << "luciole-dialog: required Wayland interfaces missing\n";
    return 1;
  }

  app.surface = wl_compositor_create_surface(app.compositor);
  app.xdg_surf = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
  xdg_surface_add_listener(app.xdg_surf, &xdg_surf_listener, &app);

  app.toplevel = xdg_surface_get_toplevel(app.xdg_surf);
  xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, &app);
  xdg_toplevel_set_title(app.toplevel, app.title.c_str());
  xdg_toplevel_set_app_id(app.toplevel, "dev.noctalia.luciole-dialog");
  xdg_toplevel_set_min_size(app.toplevel, app.width, app.height);
  xdg_toplevel_set_max_size(app.toplevel, app.width, app.height);

  wl_surface_commit(app.surface);

  while (app.running && wl_display_dispatch(app.display) != -1) {
    // Event loop
  }

  if (app.exit_code == 0 && !app.selected_value.empty()) {
    std::cout << app.selected_value << "\n";
  }

  // Cleanup
  if (app.toplevel) xdg_toplevel_destroy(app.toplevel);
  if (app.xdg_surf) xdg_surface_destroy(app.xdg_surf);
  if (app.surface) wl_surface_destroy(app.surface);
  if (app.keyboard) wl_keyboard_destroy(app.keyboard);
  if (app.pointer) wl_pointer_destroy(app.pointer);
  if (app.seat) wl_seat_destroy(app.seat);
  if (app.wm_base) xdg_wm_base_destroy(app.wm_base);
  if (app.shm) wl_shm_destroy(app.shm);
  if (app.compositor) wl_compositor_destroy(app.compositor);
  if (app.registry) wl_registry_destroy(app.registry);
  if (app.xkb_st) xkb_state_unref(app.xkb_st);
  if (app.xkb_map) xkb_keymap_unref(app.xkb_map);
  if (app.xkb_ctx) xkb_context_unref(app.xkb_ctx);
  if (app.display) wl_display_disconnect(app.display);

  return app.exit_code;
}
