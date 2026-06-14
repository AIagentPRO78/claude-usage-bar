#!/bin/bash
# Regenerate the app icon: assets/AppIcon_1024.png master -> assets/AppIcon.icns.
# Requires python3 + Pillow (pip install pillow) and macOS iconutil/sips.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p assets

python3 - <<'PY'
from PIL import Image, ImageDraw, ImageFilter
import math
S = 2048  # supersample, downscale to 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
m = int(S*0.094); box = (m, m, S-m, S-m); side = box[2]-box[0]; radius = int(side*0.225)
top, bot = (226, 127, 90), (179, 86, 58)  # Claude coral -> terracotta
grad = Image.new("RGBA", (side, side), (0, 0, 0, 0)); gd = ImageDraw.Draw(grad)
for y in range(side):
    t = y/side
    gd.line([(0, y), (side, y)], fill=(int(top[0]+(bot[0]-top[0])*t),
            int(top[1]+(bot[1]-top[1])*t), int(top[2]+(bot[2]-top[2])*t), 255))
mask = Image.new("L", (side, side), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, side, side), radius=radius, fill=255)
img.paste(grad, (box[0], box[1]), mask)
sheen = Image.new("RGBA", (side, side), (0, 0, 0, 0)); sd = ImageDraw.Draw(sheen)
for y in range(int(side*0.5)):
    sd.line([(0, y), (side, y)], fill=(255, 255, 255, int(38*(1-y/(side*0.5)))))
img.paste(sheen, (box[0], box[1]),
          Image.composite(sheen.split()[3], Image.new("L", (side, side), 0), mask))

def sparkle(draw, cx, cy, R, r, color):
    pts = []
    for i in range(8):
        ang = math.pi/2 - i*(math.pi/4); rad = R if i % 2 == 0 else r
        pts.append((cx+rad*math.cos(ang), cy-rad*math.sin(ang)))
    draw.polygon(pts, fill=color)

cream = (255, 247, 237, 255)
cx, cy = S//2, int(S*0.405); R, r = int(S*0.205), int(S*0.062)
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sparkle(ImageDraw.Draw(sh), cx, cy+int(S*0.012), R, r, (90, 35, 20, 120))
img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(S*0.011)))
sparkle(d, cx, cy, R, r, cream)
sparkle(d, int(S*0.675), int(S*0.27), int(S*0.066), int(S*0.020), (255, 255, 255, 235))
bw, gap = int(S*0.052), int(S*0.030); heights = [0.075, 0.120, 0.095, 0.150, 0.110]
total = len(heights)*bw + (len(heights)-1)*gap; x0 = cx-total//2; baseY = int(S*0.795)
for h in heights:
    bh = int(S*h)
    d.rounded_rectangle((x0, baseY-bh, x0+bw, baseY), radius=bw//2, fill=(255, 247, 237, 230))
    x0 += bw + gap
img.resize((1024, 1024), Image.LANCZOS).save("assets/AppIcon_1024.png")
print("master -> assets/AppIcon_1024.png")
PY

ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"; M="assets/AppIcon_1024.png"
sips -z 16 16   "$M" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$M" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$M" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$M" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$M" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$M" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$M" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$M" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$M" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$M" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
echo "built assets/AppIcon.icns"
