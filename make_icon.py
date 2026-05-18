from PIL import Image

# Load the user's image
img = Image.open("/Users/jbeeren/.gemini/antigravity/brain/b2063cb6-91c3-4999-9c89-03f320e485ad/media__1778754420847.png")
img = img.convert("RGBA")

data = img.getdata()
new_data = []

# The orange color has high red/green, low blue. Black has low everything.
for item in data:
    r, g, b, a = item
    if r > 100 and g > 50:  # It's orange-ish
        # Make it solid black for the template
        new_data.append((0, 0, 0, 255))
    else:
        # Make the black background transparent
        new_data.append((0, 0, 0, 0))

img.putdata(new_data)

# Crop to the actual bars to remove the padding? Or keep padding?
# Let's crop it tightly to the bars
bbox = img.getbbox()
if bbox:
    img = img.crop(bbox)

# A menu bar icon should be about 18x18 for 1x, 36x36 for @2x, 54x54 for @3x.
# Let's create an @2x image. Max height is around 32, max width is around 32.
img.thumbnail((36, 36), Image.Resampling.LANCZOS)
img.save("MenuBarIcon.png")
img.thumbnail((18, 18), Image.Resampling.LANCZOS)
img.save("MenuBarIcon_1x.png")
img.thumbnail((54, 54), Image.Resampling.LANCZOS)
img.save("MenuBarIcon_3x.png")

print("Icons generated!")
