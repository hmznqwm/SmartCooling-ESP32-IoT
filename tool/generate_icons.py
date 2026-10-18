import os
from PIL import Image

src_opt = r'c:\Kuliah Hami S3\CS\wokwi_sistem_pendingin_esp32\mobile\assets\logo\LogoRemote_optimized.png'
base_res = r'c:\Kuliah Hami S3\CS\wokwi_sistem_pendingin_esp32\mobile\android\app\src\main\res'

# 1. Background color XML
val_dir = os.path.join(base_res, 'values')
os.makedirs(val_dir, exist_ok=True)
with open(os.path.join(val_dir, 'ic_launcher_background.xml'), 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n')
    f.write('<resources>\n')
    f.write('    <color name="ic_launcher_background">#FFFFFF</color>\n')
    f.write('</resources>\n')

# 2. Adaptive Icon XML
v26_dir = os.path.join(base_res, 'mipmap-anydpi-v26')
os.makedirs(v26_dir, exist_ok=True)
xml_content = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n'
)
with open(os.path.join(v26_dir, 'ic_launcher.xml'), 'w', encoding='utf-8') as f:
    f.write(xml_content)
with open(os.path.join(v26_dir, 'ic_launcher_round.xml'), 'w', encoding='utf-8') as f:
    f.write(xml_content)

# 3. Open cropped logo
img = Image.open(src_opt).convert('RGBA')
w, h = img.size
min_x, min_y, max_x, max_y = w, h, 0, 0
for y in range(h):
    for x in range(w):
        r, g, b, a = img.getpixel((x, y))
        if r < 240 or g < 240 or b < 240:
            if x < min_x: min_x = x
            if x > max_x: max_x = x
            if y < min_y: min_y = y
            if y > max_y: max_y = y

emblem = img.crop((min_x, min_y, max_x + 1, max_y + 1))
print(f'Isolated emblem bbox: {min_x}, {min_y}, {max_x}, {max_y} -> size: {emblem.size}')

# 4. Generate Legacy Icons (ic_launcher.png & ic_launcher_round.png)
legacy_sizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

for folder, size in legacy_sizes.items():
    out_dir = os.path.join(base_res, folder)
    os.makedirs(out_dir, exist_ok=True)
    canvas = Image.new('RGBA', (size, size), (255, 255, 255, 255))
    target_h = int(size * 0.85)
    aspect = emblem.width / emblem.height
    target_w = int(target_h * aspect)
    resized_emb = emblem.resize((target_w, target_h), Image.Resampling.LANCZOS)
    pos_x = (size - target_w) // 2
    pos_y = (size - target_h) // 2
    canvas.paste(resized_emb, (pos_x, pos_y), resized_emb)
    canvas.save(os.path.join(out_dir, 'ic_launcher.png'))
    canvas.save(os.path.join(out_dir, 'ic_launcher_round.png'))
    print(f'Generated {folder} legacy icon: {size}x{size}')

# 5. Generate Adaptive Foreground Icons (ic_launcher_foreground.png)
adaptive_sizes = {
    'mipmap-mdpi': 108,
    'mipmap-hdpi': 162,
    'mipmap-xhdpi': 216,
    'mipmap-xxhdpi': 324,
    'mipmap-xxxhdpi': 432,
}

for folder, size in adaptive_sizes.items():
    out_dir = os.path.join(base_res, folder)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    target_h = int(size * 0.70)
    aspect = emblem.width / emblem.height
    target_w = int(target_h * aspect)
    resized_emb = emblem.resize((target_w, target_h), Image.Resampling.LANCZOS)
    pos_x = (size - target_w) // 2
    pos_y = (size - target_h) // 2
    canvas.paste(resized_emb, (pos_x, pos_y), resized_emb)
    canvas.save(os.path.join(out_dir, 'ic_launcher_foreground.png'))
    print(f'Generated {folder} adaptive foreground: {size}x{size}')

print('All launcher icons generated successfully!')
