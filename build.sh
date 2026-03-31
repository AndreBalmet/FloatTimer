#!/bin/bash
set -euo pipefail

# Build FloatTimer.app — a self-contained macOS app bundle
# Usage: ./build.sh

APP_NAME="FloatTimer"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS" "$RESOURCES"

echo "→ Compiling FloatTimer.swift..."
swiftc "$(dirname "$0")/FloatTimer.swift" \
    -o "$MACOS/$APP_NAME" \
    -O \
    -whole-module-optimization \
    -target "$(uname -m)-apple-macosx13.0"

echo "→ Writing Info.plist..."
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>FloatTimer</string>
    <key>CFBundleDisplayName</key>
    <string>Float Timer</string>
    <key>CFBundleIdentifier</key>
    <string>com.floattimer.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>FloatTimer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "→ Generating app icon..."
# Generate a simple icon using macOS built-in Python + Core Graphics
python3 << 'PYICON'
import subprocess, tempfile, os, struct, zlib

BUILD_DIR = os.environ.get("BUILD_DIR", "build")
RESOURCES = os.path.join(BUILD_DIR, "FloatTimer.app", "Contents", "Resources")

# Generate PNG icon using sips-friendly approach: create with Core Graphics via Python
# We'll make a simple timer icon: dark rounded rect with a clock-like circle
import ctypes, ctypes.util

# Use a simpler approach: generate PNG bytes directly
def create_png(size):
    """Create a simple timer icon as PNG."""
    pixels = bytearray(size * size * 4)
    cx, cy = size / 2, size / 2
    r_outer = size * 0.42
    r_inner = size * 0.38
    r_bg = size * 0.46

    for y in range(size):
        for x in range(size):
            idx = (y * size + x) * 4
            dx, dy = x - cx, y - cy
            dist = (dx*dx + dy*dy) ** 0.5

            # Background: rounded rectangle (approximate with large circle)
            if dist <= r_bg:
                # Dark background
                bg_alpha = min(1.0, max(0, (r_bg - dist) / 1.5))

                # Clock ring
                if r_inner <= dist <= r_outer:
                    ring_alpha = min(1.0, (dist - r_inner) / 1.2) * min(1.0, (r_outer - dist) / 1.2)
                    pixels[idx] = int(220 * ring_alpha + 30 * (1 - ring_alpha))   # R
                    pixels[idx+1] = int(220 * ring_alpha + 30 * (1 - ring_alpha)) # G
                    pixels[idx+2] = int(230 * ring_alpha + 35 * (1 - ring_alpha)) # B
                    pixels[idx+3] = int(bg_alpha * 255)
                else:
                    # Inside circle or outside ring
                    pixels[idx] = 30     # R
                    pixels[idx+1] = 30   # G
                    pixels[idx+2] = 35   # B
                    pixels[idx+3] = int(bg_alpha * 255)

                # Clock hands (minute hand pointing up-right)
                # Hour hand
                hx, hy = dx / r_inner, -dy / r_inner  # normalized, y-flipped
                # Draw a line from center toward 2 o'clock
                import math
                angle_h = math.radians(60)  # 2 o'clock
                hand_dx = math.sin(angle_h)
                hand_dy = math.cos(angle_h)
                hand_len = 0.55
                # Distance from point to line segment
                t = max(0, min(hand_len, hx * hand_dx + hy * hand_dy))
                px, py = hand_dx * t, hand_dy * t
                hand_dist = ((hx - px)**2 + (hy - py)**2) ** 0.5
                if hand_dist < 0.045 and dist < r_inner * 0.95:
                    pixels[idx] = 255; pixels[idx+1] = 255; pixels[idx+2] = 255
                    pixels[idx+3] = int(bg_alpha * 255)

                # Minute hand toward 12 o'clock
                angle_m = math.radians(0)
                mhand_dx = math.sin(angle_m)
                mhand_dy = math.cos(angle_m)
                mhand_len = 0.75
                t2 = max(0, min(mhand_len, hx * mhand_dx + hy * mhand_dy))
                px2, py2 = mhand_dx * t2, mhand_dy * t2
                mhand_dist = ((hx - px2)**2 + (hy - py2)**2) ** 0.5
                if mhand_dist < 0.035 and dist < r_inner * 0.95:
                    pixels[idx] = 255; pixels[idx+1] = 255; pixels[idx+2] = 255
                    pixels[idx+3] = int(bg_alpha * 255)

                # Center dot
                if dist < size * 0.025:
                    pixels[idx] = 255; pixels[idx+1] = 255; pixels[idx+2] = 255
                    pixels[idx+3] = int(bg_alpha * 255)
            else:
                pixels[idx] = 0; pixels[idx+1] = 0; pixels[idx+2] = 0; pixels[idx+3] = 0

    # Encode as PNG
    def encode_png(width, height, rgba_data):
        def chunk(ctype, data):
            c = ctype + data
            return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

        sig = b'\x89PNG\r\n\x1a\n'
        ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)

        raw = bytearray()
        stride = width * 4
        for y in range(height):
            raw.append(0)  # filter: none
            raw.extend(rgba_data[y*stride:(y+1)*stride])

        idat = zlib.compress(bytes(raw), 9)
        return sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')

    return encode_png(size, size, bytes(pixels))

# Generate multiple sizes for iconset
sizes = [16, 32, 64, 128, 256, 512, 1024]
iconset_dir = os.path.join(RESOURCES, "AppIcon.iconset")
os.makedirs(iconset_dir, exist_ok=True)

size_map = {
    16: "icon_16x16.png",
    32: "icon_16x16@2x.png",
    64: "icon_32x32@2x.png",
    128: "icon_128x128.png",
    256: "icon_128x128@2x.png",
    512: "icon_256x256@2x.png",
    1024: "icon_512x512@2x.png",
}

# Also need 1x versions
size_map_1x = {
    32: "icon_32x32.png",
    256: "icon_256x256.png",
    512: "icon_512x512.png",
}

for sz in sizes:
    png = create_png(sz)
    if sz in size_map:
        with open(os.path.join(iconset_dir, size_map[sz]), 'wb') as f:
            f.write(png)
    if sz in size_map_1x:
        with open(os.path.join(iconset_dir, size_map_1x[sz]), 'wb') as f:
            f.write(png)

print("  Icon PNGs generated")
PYICON

# Convert iconset to icns
iconutil -c icns "$RESOURCES/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns" 2>/dev/null && \
    echo "→ App icon created" || echo "→ Warning: iconutil failed, app will use default icon"
rm -rf "$RESOURCES/AppIcon.iconset"

echo "→ Ad-hoc code signing..."
codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "✓ Built: $APP_BUNDLE"
echo ""
echo "  To install:  cp -r \"$APP_BUNDLE\" /Applications/"
echo "  To run:      open \"$APP_BUNDLE\""
echo "  To share:    zip the .app and send it (recipients may need to right-click → Open on first launch)"
