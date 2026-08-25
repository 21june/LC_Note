from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
source = root / "assets" / "branding" / "my_listener_icon.png"
image = Image.open(source).convert("RGB")
# Image generation intentionally used a rounded-square composition. Fill only
# the connected black corner area so legacy square launchers also look polished.
for point in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)]:
    ImageDraw.floodfill(image, point, (5, 30, 39), thresh=28)
image.save(source, optimize=True)

def save_png(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)

android = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
for folder, size in android.items():
    save_png(root / "android" / "app" / "src" / "main" / "res" / folder / "ic_launcher.png", size)

for name, size in {
    "Icon-192.png": 192,
    "Icon-512.png": 512,
    "Icon-maskable-192.png": 192,
    "Icon-maskable-512.png": 512,
}.items():
    save_png(root / "web" / "icons" / name, size)
save_png(root / "web" / "favicon.png", 32)

ios = root / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ios_sizes = {
    "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
}
for name, size in ios_sizes.items():
    save_png(ios / name, size)

ico = image.resize((256, 256), Image.Resampling.LANCZOS)
ico.save(root / "windows" / "runner" / "resources" / "app_icon.ico", sizes=[(16,16), (32,32), (48,48), (64,64), (128,128), (256,256)])

print(f"Generated launcher icons from {source}")
