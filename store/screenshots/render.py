#!/usr/bin/env python3
"""
Render pixel-accurate StrongRow screen states, mirroring StrongRowView.onUpdate:
same device resolutions, layout fractions (0.12/0.30/0.55/0.75/0.87), fonts,
and Garmin color constants. Not literal simulator captures (live workout states
need GUI sensor playback + button input) but faithful to the draw code.
"""
from PIL import Image, ImageDraw, ImageFont
import os

OUT = os.path.dirname(os.path.abspath(__file__))
BOLD = "C:/Windows/Fonts/arialbd.ttf"
BLK  = "C:/Windows/Fonts/ariblk.ttf"

# Garmin Graphics color constants (approx to the palette)
BLACK=(0,0,0); WHITE=(255,255,255); LTGRAY=(178,178,178)
GREEN=(0,214,64); ORANGE=(255,96,0); YELLOW=(255,214,0); RED=(230,45,45)

# font-size fractions of screen height, approximating the Garmin device fonts
FR = {
    "XTINY":0.058, "TINY":0.070, "SMALL":0.080, "MEDIUM":0.100,
    "NUM_MILD":0.135, "NUM_HOT":0.245, "NUM_THAI_HOT":0.300,
}

def font(path, px):
    return ImageFont.truetype(path, int(px))

def draw(dc, w, h, cx, yf, key, text, color, vcenter=False, numeric=True):
    px = FR[key]*h
    f = font(BLK if numeric else BOLD, px)
    anchor = "mm" if vcenter else "ma"   # middle-top unless vertically centered
    dc.text((cx, yf*h), text, font=f, fill=color, anchor=anchor)

def render(dev, w, h, state, big_key):
    img = Image.new("RGB",(w,h),BLACK)
    dc = ImageDraw.Draw(img)
    cx = w/2

    title=state["title"]; tcol=state.get("tcol",LTGRAY)
    draw(dc,w,h,cx,0.12,"SMALL",title,tcol,numeric=False)

    mid=state.get("mid")            # (text,font_key,color,numeric)
    if mid:
        draw(dc,w,h,cx,0.30,mid[1],mid[0],mid[2],vcenter=True,numeric=mid[3])

    val=state["val"]; vcol=state["vcol"]
    draw(dc,w,h,cx,0.55,big_key,val,vcol,vcenter=True,numeric=True)

    sub=state.get("sub")
    if sub:
        draw(dc,w,h,cx,0.75,"XTINY",sub[0],sub[1],numeric=False)

    foot=state.get("foot")
    if foot:
        draw(dc,w,h,cx,0.87,"XTINY",foot[0],foot[1],numeric=False)

    p=os.path.join(OUT,f"{dev}-{state['id']}.png")
    img.save(p)
    return p

# workout-mode states (device-independent content)
STATES = [
    {"id":"1-ready","title":"5x4'","mid":("START to begin","TINY",LTGRAY,False),
     "val":"--.-","vcol":WHITE,"sub":("target 16-18 spm",LTGRAY),
     "foot":("START to record",LTGRAY)},
    {"id":"2-work-in","title":"WORK 3/5","mid":("2:34","NUM_MILD",WHITE,True),
     "val":"17.2","vcol":GREEN,"sub":("target 16-18 spm",LTGRAY),
     "foot":("REC 12:04   148 str",RED)},
    {"id":"3-work-out","title":"WORK 2/5","mid":("3:41","NUM_MILD",WHITE,True),
     "val":"19.6","vcol":ORANGE,"sub":("target 16-18 spm",LTGRAY),
     "foot":("REC 6:02   74 str",RED)},
    {"id":"4-rest","title":"REST","mid":("1:12","NUM_MILD",WHITE,True),
     "val":"--.-","vcol":WHITE,"sub":("next: WORK 3",LTGRAY),
     "foot":("REC 8:30   96 str",RED)},
    {"id":"5-gate","title":"READY","mid":("PRESS START","MEDIUM",YELLOW,False),
     "val":"--.-","vcol":WHITE,"sub":("to start WORK 4",LTGRAY),
     "foot":("REC 14:20   170 str",RED)},
    {"id":"6-done","title":"DONE","val":"--.-","vcol":WHITE,
     "sub":("BACK to save",LTGRAY),"foot":("REC 30:00   358 str",RED)},
]
# free-row mode (workout disabled)
FREE = {"id":"7-free","title":"ROW SPM","val":"22.5","vcol":WHITE,
        "sub":("free row",LTGRAY),"foot":("REC 5:18   115 str",RED)}

DEVICES = [("fr970",454,454,"NUM_THAI_HOT"), ("fenix6",260,260,"NUM_HOT")]

made=[]
for dev,w,h,bigk in DEVICES:
    for st in STATES:
        made.append(render(dev,w,h,st,bigk))
    made.append(render(dev,w,h,FREE,bigk))

# contact sheet of the fr970 set for quick review
fr=[p for p in made if os.path.basename(p).startswith("fr970")]
cols=4; pad=16; thumb=300
rows=(len(fr)+cols-1)//cols
sheet=Image.new("RGB",(cols*thumb+(cols+1)*pad, rows*thumb+(rows+1)*pad),(25,25,25))
for i,p in enumerate(sorted(fr)):
    im=Image.open(p).resize((thumb,thumb))
    r,c=divmod(i,cols)
    sheet.paste(im,(pad+c*(thumb+pad), pad+r*(thumb+pad)))
sheet.save(os.path.join(OUT,"_contact_sheet.png"))
print(f"rendered {len(made)} screenshots + contact sheet")
for p in sorted(made): print("  ", os.path.basename(p))
