"""App Store screenshots with a caption: 1320x2868 (6.9" iPhone), RGB, no alpha.
Usage: python3 tools/make_marketing.py <raw-shots-dir> <out-dir>
Raw shots come from the simulator in demo mode (see README: -demo YES -shot <name>)."""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = lambda w, size: ImageFont.truetype(os.path.join(ROOT, "App", "Fonts", f"Pretendard-{w}.otf"), size)

SHOTS = [
    # No price words anywhere in screenshots (App Review 2.3.7): the "paywall" half of the slogan lives in the
    # description and the README only.
    ("home", "Focus is a human right.", "Schedules, daily limits and time-outs\nfor apps and websites. Nothing held back."),
    ("place", "Locks where you are.", "Pick places on the map. Apps lock when\nyou arrive and open when you leave."),
    ("timeout", "Take a breather.", "After a stretch of use, a short break.\nIt starts over at the time you pick."),
    ("limits", "Limits that stick.", "See the minutes left. Used up means\nlocked until the limit resets."),
    ("editor", "No early exit.", "With Strict lock, a running block\ncan't be stopped or deleted."),
    ("appearance", "Make it yours.", "Five themes, each with\na matching app icon."),
    ("lockin", "Lock in for days.", "Freeze every rule. No loosening,\nno deleting apps."),
]
# Korean captions (filled in from the reviewed translation): name -> (title, subtitle)
SHOTS_KO = {
    "home": (
        "집중은 모두의 권리",
        "앱과 웹사이트 일정 설정\n스크린 타임을 직접 관리"
    ),
    "place": (
        "도착하면 잠깁니다",
        "지도에서 장소 선택\n도착하면 잠기고 떠나면 해제"
    ),
    "timeout": (
        "잠시 쉬어 가세요",
        "한동안 사용하면 잠시 쉬고\n정한 시각에 다시 시작"
    ),
    "limits": (
        "한도는 지켜집니다",
        "남은 시간 확인\n한도를 다 쓰면 초기화될 때까지 잠금"
    ),
    "editor": (
        "중간에 해제할 수 없어요",
        "강제 잠금 사용 시 실행 중인 차단을\n중지하거나 삭제할 수 없습니다."
    ),
    "appearance": (
        "내 취향대로",
        "다섯 가지 테마와\n어울리는 앱 아이콘"
    ),
    "lockin": (
        "며칠 동안 규칙 고정",
        "모든 규칙을 고정\n완화 및 앱 삭제 불가"
    )
}

W, H = 1320, 2868
INK, MUTED, BRASS = (233, 230, 223), (154, 161, 177), (200, 169, 106)


def background():
    img = Image.new("RGB", (W, H))
    top, bottom = (17, 25, 48), (10, 15, 28)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([W / 2 - 900, -1100, W / 2 + 900, 700], fill=60)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    img = Image.composite(Image.new("RGB", (W, H), BRASS), img, glow.point(lambda v: int(v * 0.55)))
    return img


def centered(d, y, text, font, fill, spacing):
    for line in text.split("\n"):
        w = d.textlength(line, font=font)
        d.text(((W - w) / 2, y), line, font=font, fill=fill)
        y += font.size + spacing
    return y


def compose(raw, title, sub):
    img = background()
    d = ImageDraw.Draw(img)
    size = 104
    while d.textlength(title, font=FONT("Light", size)) > W - 140:
        size -= 2
    y = centered(d, 210 + (104 - size) // 2, title, FONT("Light", size), INK, 0)
    centered(d, y + 42, sub, FONT("Regular", 46), MUTED, 18)

    shot = Image.open(raw).convert("RGB")
    sw = 990
    sh = round(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    x, top = (W - sw) // 2, H - sh - 96
    radius = 64
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=radius, fill=255)
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, top + 24, x + sw, top + sh + 24], radius=radius, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    img = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), img, shadow)
    img.paste(shot, (x, top), mask)
    ImageDraw.Draw(img).rounded_rectangle([x - 2, top - 2, x + sw + 1, top + sh + 1], radius=radius + 2,
                                          outline=(92, 82, 62), width=3)
    return img


def main():
    raw_dir, out_dir = sys.argv[1], sys.argv[2]
    korean = len(sys.argv) > 3 and sys.argv[3] == "ko"
    os.makedirs(out_dir, exist_ok=True)
    for i, (name, title, sub) in enumerate(SHOTS, 1):
        if korean:
            if name not in SHOTS_KO:
                print("no Korean caption for", name); continue
            title, sub = SHOTS_KO[name]
        out = os.path.join(out_dir, f"{i:02d}-{name}.png")
        compose(os.path.join(raw_dir, f"{name}.png"), title, sub).save(out, optimize=True)
        print("wrote", out)


if __name__ == "__main__":
    main()
