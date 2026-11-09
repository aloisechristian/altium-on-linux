# Altium Designer on Linux (Native Wine Performance Guide & Auto-Installer)

Run **Altium Designer 26 (and 24/25)** on Linux under Wine with **solid 60–300+ FPS fluid hardware-accelerated Schematic (Direct2D via DXVK)** and **fluid PCB 2D/3D (Vulkan)**.

This repository provides:
1. **`install-altium-linux.sh`**: A one-click automated installer and patcher script.
2. **Pre-built optimized binaries**: Custom patched `d2d1.dll`, `win32u.so`, and `wineserver`.
3. **Source patches**: Clean upstream-ready patches for Wine 11.x fixing Direct2D/DirectWrite world-to-pixel scaling, epoll socket stalling, and mouse input coalescing.

---

## ⚡ Performance Comparison (Schematic Editor Pan & Zoom)

| Metric | Unpatched Wine  | With This Repository's Fixes | Improvement |
| :--- | :--- | :--- | :--- |
| **Pan FPS (continuous right-click drag)** | **6.8 FPS** (unusable, severe lag) | **264 – 348.2 FPS** (fluid) | **~50x faster (+4,500%)** |
| **Mouse Wheel Zoom / Scroll FPS** | ~5–7 FPS | **186 – 217 FPS** | **~35x faster** |
| **Frame Latency (DXVK HUD)** | `147.1 ms / frame` | **`0.9 ms – 3.7 ms / frame`** | **98% latency reduction** |
| **Text Rendering Quality** | Garbled / corrupt / missing text | **Razor-sharp vector & bitmap text** | **100% Fixed** |
| **CPU in FreeType `TT_RunIns`** | **23.08%** of total system CPU | **0.06%** (1 sample in 4s profile) | **-99.7% CPU overhead** |
| **CPU in `d2d1.dll`** | **69.62%** (at 6.8 FPS) | **24.77%** (at 348 FPS!) | **~80x fewer CPU cycles/frame** |


---

## 🚀 Quick Start (Automated Installer)

### Prerequisites
Make sure your system has the standard Wine dependencies installed:
- On **Arch Linux**:
  ```bash
  sudo pacman -S wine winetricks vulkan-icd-loader lib32-vulkan-icd-loader python
  ```
- On **Ubuntu / Debian**:
  ```bash
  sudo apt install wine winetricks python3
  ```
- On **Fedora**:
  ```bash
  sudo dnf install wine winetricks python3
  ```

### Automated Setup

1. **Clone this repository**:
   ```bash
   git clone https://github.com/aloisechristian/altium-on-linux.git
   cd altium-on-linux
   ```

2. **Run the installer**:
   - **For a fresh installation** (with installer `.exe`):
     ```bash
     ./install-altium-linux.sh -i ~/Downloads/AltiumDesignerSetup_26_11_1.exe
     ```
   - **To patch an existing Altium installation** (without reinstalling):
     ```bash
     ./install-altium-linux.sh --patch-only
     ```

3. **Launch Altium Designer**:
   Launch it from your application menu or run:
   ```bash
   ~/.wine-prefixes/altium/start-altium.sh
   ```

---

## 🛠️ What the Installer Fixes Automatically

1. **Google OAuth / Browser Sign-in (PKCE Native Bridge)**:
   Altium's online installer and Altium 365 login fail inside Wine because the embedded WebView cannot complete modern OAuth flows. The installer runs a native Python listener that delegates to your Linux browser (Firefox/Chrome) and transparently acquires the session token.
2. **Schematic Direct2D World-to-Pixel Font Scaling & Glyph Cache**:
   Fixes the root cause of the 6.8 FPS schematic lag in Wine Direct2D (`d2d1.dll`).
3. **`InheritWindowMonitor` Menu Crash (`C06D007F` / Abstract Error)**:
   Delphi VCL crashes when querying virtual monitor configurations under Wine. Patched in `X2.EXE`.
4. **Black Context Menus (DevExpress Layered Windows)**:
   Disables problematic fade/slide animations via registry.
5. **WPF Invisible Text / Black Boxes**:
   Configures `Avalon.Graphics` registry flags.
6. **Telemetry & Atom Table IPC Flood**:
   Patches `X2.EXE` loop that was executing 32,768 synchronous socket calls to `wineserver` every 5 seconds.
7. **Simulation Hover Flood**:
   Patches `AdvSim.dll` from triggering thousands of recursive `WindowFromPoint` and hook queries on mouse move.
8. **SamacSys Altium Library Loader (`AltiumLL.vbs`)**:
   Fixes `Permission Denied`, VBScript Base64 character conversion bugs in Wine, missing `Set` keywords on `PCBServer`/COM object assignments, and patches an Access Violation (`0xC0000005` reading `0x0`) in `ScriptingSystem.dll` when resolving dispatch fallback properties during footprint generation.

---

## 🔬 Root-Cause Analysis (Technical Deep Dive)

### Root Cause 1: Direct2D Outline Fallback & $O(N^2)$ Bézier Triangulation
- Altium Designer's Direct2D renderer (`Altium.GeometryMaker.Direct2DGraphics` via `AdvSch.dll`) specifies font sizes in **internal schematic world units** (`glyph_run->fontEmSize >= 100.0f`) and scales them down to screen pixels (e.g. 10–14px) using `context->drawing_state.transform`.
- Wine's `dlls/d2d1/device.c` passed the unscaled `fontEmSize` to `IDWriteFontFace_GetRecommendedRenderingMode`.
- In Wine's `dwrite`, `RECOMMENDED_OUTLINE_AA_THRESHOLD` is `100.0f`. Because the world font size was $\ge 100$, DirectWrite always returned `DWRITE_RENDERING_MODE_OUTLINE`.
- This forced `d2d_device_context_draw_glyph_run` into `d2d_device_context_draw_glyph_run_outline`, completely bypassing the 8,192-slot texture `glyph_cache` and executing $O(N^2)$ cubic Bézier intersection (`d2d_geometry_resolve_beziers`) and Constrained Delaunay Triangulation (`d2d_cdt_triangulate`) on **every single label on every single frame**!

### Root Cause 2: Unscaled `FT_Set_Pixel_Sizes` in DirectWrite
- Even in bitmap mode, Wine passed unscaled `fontEmSize` to `IDWriteFactory2_CreateGlyphRunAnalysis`.
- FreeType was configured with massive glyph sizes, activating bytecode hinting (`TT_RunIns`) at thousands of pixels, and then scaling the outline back with fixed-point math (`FT_Glyph_Transform`). This bypassed `dwrite.dll`'s internal glyph cache (which requires a 2x2 identity matrix) and caused text corruption.

### Root Cause 3: Epoll Socket Disarm Starvation
- During high-frequency mouse dragging (500–1000 Hz gaming mice), `process_driver_events` in `win32u.so` failed to re-arm `POLLIN` on `queue->fd` when events were still in transit.
- Wine entered sleep in `NtWaitForMultipleObjects` while `wineserver` stopped listening to the X11 connection, throttling updates to ~10 FPS until an application timer woke it up.

---

## 📂 Patches Included

In [`patches/`](patches/):
- [`01-d2d1-schematic-glyph-cache-and-scale-fix.patch`](patches/01-d2d1-schematic-glyph-cache-and-scale-fix.patch): Direct2D world-to-pixel normalization, 8,192-slot glyph cache, and fast AABB rejection.
- [`02-win32u-wineserver-poll-events-and-input.patch`](patches/02-win32u-wineserver-poll-events-and-input.patch): Inconditional epoll `POLLIN` re-arm, mouse input coalescing, and `WH_MOUSE_LL` sync bypass.
- [`00-full-wine-11.20-altium-fluid.patch`](patches/00-full-wine-11.20-altium-fluid.patch): Unified patch against Wine 11.20.

---

## ⚖️ License & Disclaimer

- The installer script and patches are released under the **LGPL-2.1 / MIT** license, consistent with Wine.
- Altium Designer is a registered trademark of Altium LLC. This project is not affiliated with, endorsed by, or sponsored by Altium LLC. A valid Altium Designer license is required to run the software.
