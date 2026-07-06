#!/usr/bin/env python3
"""Generate StrongRow store artwork: hero (1920x1080) and icon (512x512).

Scene: stylized muscular sculler at the finish of the drive, silhouetted
against a dusk sky with a low sun, single scull hull on calm water.
"""
import os

import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = HERE
LAUNCHER = os.path.join(HERE, "..", "resources", "drawables", "launcher_icon.png")

# ---------------------------------------------------------------- rower group
# Local coordinates assume a 1920x1080 canvas with the waterline at y=720.
# The figure sits centered around x ~ 1050, facing right (stern), leaning
# back toward the bow (left) at the finish of the drive.
SIL = "#0d1420"          # silhouette color
SIL_FAR = "#2a3648"      # far-side oar (behind figure)

ROWER = f'''
  <g id="rower">
    <!-- far-side oar (behind everything) -->
    <line x1="965" y1="612" x2="700" y2="775" stroke="{SIL_FAR}" stroke-width="10" stroke-linecap="round"/>
    <path d="M 736 752 L 700 775 L 652 818 L 690 810 Z" fill="{SIL_FAR}"/>

    <!-- hull -->
    <path d="M 260 706
             C 500 692, 760 688, 1000 688
             C 1240 688, 1480 694, 1660 704
             C 1500 716, 1240 722, 1000 722
             C 760 722, 470 716, 260 706 Z" fill="{SIL}"/>
    <!-- stern fin -->
    <path d="M 1470 718 L 1492 752 L 1504 718 Z" fill="{SIL}"/>
    <!-- bow ball -->
    <circle cx="258" cy="705" r="7" fill="{SIL}"/>

    <!-- foot stretcher -->
    <path d="M 1312 652 L 1328 656 L 1300 710 L 1284 706 Z" fill="{SIL}"/>

    <!-- seat -->
    <rect x="938" y="674" width="92" height="13" rx="6.5" fill="{SIL}"/>

    <!-- legs: quad capsule to a defined knee, shin down to the stretcher -->
    <line x1="995" y1="650" x2="1148" y2="620" stroke="{SIL}" stroke-width="46" stroke-linecap="round"/>
    <!-- quad bulge on top of thigh -->
    <ellipse cx="1070" cy="618" rx="52" ry="15" fill="{SIL}" transform="rotate(-11 1070 618)"/>
    <circle cx="1148" cy="622" r="23" fill="{SIL}"/>
    <line x1="1148" y1="622" x2="1252" y2="672" stroke="{SIL}" stroke-width="23" stroke-linecap="round"/>
    <!-- calf bulge -->
    <ellipse cx="1196" cy="654" rx="24" ry="11" fill="{SIL}" transform="rotate(26 1196 654)"/>
    <!-- foot on stretcher -->
    <path d="M 1244 658 L 1288 672 L 1282 696 L 1240 684 Z" fill="{SIL}"/>

    <!-- glutes -->
    <circle cx="972" cy="656" r="25" fill="{SIL}"/>

    <!-- torso: modest back lean, chest up, broad shoulders tapering to waist -->
    <path d="M 948 676
             C 930 656, 916 610, 906 566
             C 900 540, 900 522, 916 514
             C 934 506, 956 516, 964 540
             C 974 570, 982 608, 996 640
             C 1010 668, 986 690, 948 676 Z" fill="{SIL}"/>
    <!-- trap / rear delt mass -->
    <ellipse cx="922" cy="530" rx="24" ry="18" fill="{SIL}" transform="rotate(42 922 530)"/>

    <!-- head + neck, chin level (looking toward the stern) -->
    <circle cx="924" cy="488" r="33" fill="{SIL}"/>

    <!-- near oar: handle at the ribs through the oarlock into the water -->
    <line x1="962" y1="612" x2="648" y2="816" stroke="{SIL}" stroke-width="12" stroke-linecap="round"/>
    <!-- blade -->
    <path d="M 694 780 L 648 816 L 590 864 L 630 858 Z" fill="{SIL}"/>
    <!-- splash where the shaft meets the water -->
    <path d="M 764 738 Q 786 726 810 736" stroke="#f2d8a8" stroke-width="5" fill="none" opacity="0.7"/>
    <!-- rigger to oarlock -->
    <path d="M 910 700 L 830 700 L 826 690 L 868 690 Z" fill="{SIL}"/>
    <circle cx="828" cy="698" r="9" fill="{SIL}"/>

    <!-- arm: thick upper arm to a drawn-back elbow, forearm to the handle -->
    <line x1="926" y1="540" x2="856" y2="622" stroke="{SIL}" stroke-width="34" stroke-linecap="round"/>
    <line x1="856" y1="622" x2="958" y2="614" stroke="{SIL}" stroke-width="24" stroke-linecap="round"/>
    <!-- deltoid -->
    <circle cx="928" cy="538" r="24" fill="{SIL}"/>
    <!-- fist -->
    <circle cx="962" cy="612" r="13" fill="{SIL}"/>
  </g>
'''

SKY_WATER = '''
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#101c30"/>
      <stop offset="0.45" stop-color="#3b2f4a"/>
      <stop offset="0.78" stop-color="#c05f33"/>
      <stop offset="1" stop-color="#f2a548"/>
    </linearGradient>
    <linearGradient id="water" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#173142"/>
      <stop offset="1" stop-color="#0b1826"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#ffd98a" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#ffd98a" stop-opacity="0"/>
    </radialGradient>
  </defs>
'''

def scene(w=1920, h=1080, waterline=720, sun_cx=960, sun_r=260, with_text=True):
    reflect = []
    # sun reflection column: horizontal amber dashes fading downward
    import_y = waterline + 26
    widths = [300, 240, 320, 200, 260, 150, 200, 110, 140, 80]
    for i, ww in enumerate(widths):
        y = import_y + i * 30
        op = max(0.05, 0.38 - i * 0.035)
        reflect.append(
            f'<rect x="{sun_cx - ww/2}" y="{y}" width="{ww}" height="7" rx="3.5" '
            f'fill="#f7b45c" opacity="{op:.2f}"/>'
        )
    ripples = []
    for i, (x, y, ww) in enumerate([(300, 780, 260), (1500, 770, 300), (520, 900, 340),
                                    (1350, 920, 280), (240, 1000, 300), (1580, 1010, 240)]):
        ripples.append(f'<rect x="{x}" y="{y}" width="{ww}" height="5" rx="2.5" '
                       f'fill="#3d6a7a" opacity="0.5"/>')

    text = ''
    if with_text:
        text = f'''
  <text x="960" y="170" text-anchor="middle" font-family="DejaVu Sans" font-weight="bold"
        font-size="118" letter-spacing="26" fill="#f7f3ea">STRONGROW</text>
  <text x="960" y="238" text-anchor="middle" font-family="DejaVu Sans"
        font-size="34" letter-spacing="10" fill="#f5b45f">LOW-RATE ROWING &#183; MEASURED TO A TENTH</text>
'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 1920 1080">
  {SKY_WATER}
  <rect width="1920" height="{waterline}" fill="url(#sky)"/>
  <circle cx="{sun_cx}" cy="{waterline}" r="{sun_r * 2.2}" fill="url(#glow)"/>
  <circle cx="{sun_cx}" cy="{waterline - 40}" r="{sun_r}" fill="#f6b352"/>
  <rect y="{waterline}" width="1920" height="{1080 - waterline}" fill="url(#water)"/>
  {''.join(reflect)}
  {''.join(ripples)}
  {text}
  {ROWER}
</svg>'''


def icon():
    # 512x512 rounded square, simplified: sun + water + rower scaled down.
    waterline = 720
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  {SKY_WATER}
  <clipPath id="rr"><rect width="512" height="512" rx="96"/></clipPath>
  <g clip-path="url(#rr)">
    <rect width="512" height="340" fill="url(#sky)"/>
    <circle cx="256" cy="330" r="150" fill="#f6b352"/>
    <rect y="340" width="512" height="172" fill="url(#water)"/>
    <rect x="150" y="368" width="212" height="8" rx="4" fill="#f7b45c" opacity="0.4"/>
    <rect x="190" y="398" width="132" height="8" rx="4" fill="#f7b45c" opacity="0.28"/>
    <rect x="120" y="430" width="180" height="7" rx="3.5" fill="#3d6a7a" opacity="0.5"/>
    <g transform="translate(256 340) scale(0.5) translate(-1060 -{waterline})">
      {ROWER}
    </g>
  </g>
</svg>'''


hero_svg = scene()
open(f"{OUT}/hero.svg", "w").write(hero_svg)
cairosvg.svg2png(bytestring=hero_svg.encode(), write_to=f"{OUT}/hero.png",
                 output_width=1920, output_height=1080)

icon_svg = icon()
cairosvg.svg2png(bytestring=icon_svg.encode(), write_to=LAUNCHER,
                 output_width=80, output_height=80)
open(f"{OUT}/icon.svg", "w").write(icon_svg)
cairosvg.svg2png(bytestring=icon_svg.encode(), write_to=f"{OUT}/icon.png",
                 output_width=512, output_height=512)
print("done")
