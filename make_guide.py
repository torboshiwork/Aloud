#!/usr/bin/env python3
"""Render the Thai install/usage guide handed out with the DMG.

Deliberately says "ไฟล์ .dmg ที่ได้รับ" rather than a filename: the first version
of this named Aloud-2.1.0.dmg and went stale the moment the version moved.
SukhumvitSet has no ⚠ or → glyph, so both are drawn rather than typed.
"""
from PIL import Image, ImageDraw, ImageFont
import pathlib, sys

TH = "/System/Library/Fonts/SukhumvitSet.ttc"
OUT = sys.argv[1] if len(sys.argv) > 1 else "วิธีติดตั้งและใช้งาน.png"
LOGO = pathlib.Path(__file__).parent / "assets" / "logo.png"

def f(sz): return ImageFont.truetype(TH, sz)
W=1200; BG=(11,17,38); CARD=(19,28,58); WHITE=(255,255,255)
BLUE=(90,165,255); DIM=(150,170,210); WARN_BG=(60,40,20); WARN_FG=(255,190,90)
im = Image.new("RGB",(W,2400),BG); d = ImageDraw.Draw(im)

def wrap(t,font,maxw):
    out,line=[],""
    for w in t.split(" "):
        s=(line+" "+w).strip()
        if d.textlength(s,font=font)<=maxw: line=s
        else:
            if line: out.append(line)
            line=w
    if line: out.append(line)
    return out
def card(y,h,c=CARD): d.rounded_rectangle([60,y,W-60,y+h],radius=22,fill=c)
def num(x,y,n,r=26):
    d.ellipse([x-r,y-r,x+r,y+r],fill=BLUE)
    d.text((x-d.textlength(str(n),font=f(30))/2,y-22),str(n),font=f(30),fill=(8,14,32))
def arrow(x,y,w=34,c=BLUE):
    d.rectangle([x,y-1,x+w-11,y+2],fill=c)
    d.polygon([(x+w-13,y-8),(x+w,y),(x+w-13,y+8)],fill=c)
def warn_icon(x,y,s=30,c=WARN_FG):
    d.polygon([(x,y-s//2),(x-s//2,y+s//2),(x+s//2,y+s//2)],outline=c,width=3)
    d.rectangle([x-2,y-6,x+1,y+6],fill=c); d.rectangle([x-2,y+11,x+1,y+14],fill=c)

logo = Image.open(LOGO).convert("RGBA").resize((150,150),Image.LANCZOS)
im.paste(logo,(int(W/2-75),60),logo)
for t,sz,c,yy in [("Aloud",80,WHITE,225),("พูดแล้วให้ Mac พิมพ์ให้",38,DIM,325),("คู่มือติดตั้งและใช้งาน",30,BLUE,385)]:
    d.text(((W-d.textlength(t,font=f(sz)))/2,yy),t,font=f(sz),fill=c)

y=470
def section(t,y):
    d.text((70,y),t,font=f(40),fill=WHITE); d.line([70,y+62,W-70,y+62],fill=(45,60,100),width=2); return y+92

y=section("ติดตั้ง",y)
for i,(h,sub) in enumerate([("เปิดไฟล์ .dmg ที่ได้รับ","ดับเบิลคลิกที่ไฟล์ จะมีหน้าต่างเด้งขึ้นมา"),
                            ("ลาก Aloud ไปใส่ Applications","ในหน้าต่างนั้นจะเห็นไอคอนแอปกับโฟลเดอร์ Applications ลากใส่ได้เลย")],1):
    card(y,132); num(120,y+66,i)
    d.text((175,y+30),h,font=f(34),fill=WHITE)
    for j,l in enumerate(wrap(sub,f(26),W-260)): d.text((175,y+80+j*32),l,font=f(26),fill=DIM)
    y+=152

y=section("เปิดครั้งแรก — ต้องทำขั้นตอนนี้",y)
card(y,300,WARN_BG); warn_icon(108,y+45)
d.text((140,y+26),"จะขึ้นเตือนว่าเปิดไม่ได้ — เป็นเรื่องปกติ",font=f(32),fill=WARN_FG)
for j,l in enumerate(wrap("แอปนี้ยังไม่ได้ผ่าน notarization ของ Apple (ต้องเสียเงินปีละ $99) ไม่ได้แปลว่ามีอะไรผิดปกติ ทำตามนี้ครั้งเดียวพอ",f(26),W-220)):
    d.text((100,y+84+j*34),l,font=f(26),fill=(230,205,165))
for j,l in enumerate(["1.  ดับเบิลคลิก Aloud หนึ่งครั้ง (โดนเตือน กด OK ไปก่อน)",
                      "2.  เปิด System Settings › Privacy & Security",
                      "3.  เลื่อนลงจะเห็นข้อความพูดถึง Aloud แล้วกด Open Anyway"]):
    d.text((110,y+164+j*38),l,font=f(27),fill=WARN_FG)
y+=325

y=section("เปิดสิทธิ์ 2 อย่าง",y); card(y,195)
d.text((100,y+26),"System Settings › Privacy & Security",font=f(28),fill=BLUE)
for j,(k,v) in enumerate([("Microphone","ไม่เปิด = ไม่ได้ยินเสียงที่พูด"),
                          ("Accessibility","ไม่เปิด = ถอดเสียงได้ แต่ไม่พิมพ์ออกมา")]):
    d.ellipse([112,y+92+j*48,124,y+104+j*48],fill=BLUE)
    d.text((145,y+80+j*48),k,font=f(30),fill=WHITE)
    d.text((375,y+84+j*48),v,font=f(25),fill=DIM)
y+=220

y=section("ใส่ API key ของตัวเอง (ฟรี)",y); card(y,215)
for j,l in enumerate(["1.  เข้า console.groq.com  สมัคร แล้วสร้าง API key",
                      "2.  คลิกไอคอนไมค์บนแถบเมนูด้านบนจอ แล้วเลือก Settings…",
                      "3.  วาง key ลงไป แล้วกด Save"]):
    d.text((100,y+30+j*46),l,font=f(28),fill=WHITE)
d.text((100,y+172),"key เก็บไว้ในเครื่องคุณเองที่ ~/.aloud/ ไม่ได้ส่งไปไหน",font=f(24),fill=DIM)
y+=240

y=section("วิธีใช้",y); card(y,180)
seg=["กด  Fn  ค้าง","พูด","ปล่อย"]; fu=f(44)
x=(W-(sum(d.textlength(s,font=fu) for s in seg)+2*54))/2
for i,s in enumerate(seg):
    d.text((x,y+38),s,font=fu,fill=BLUE); x+=d.textlength(s,font=fu)
    if i<2: arrow(int(x+12),y+62); x+=54
t="ข้อความจะพิมพ์ลงตรงที่เคอร์เซอร์อยู่ ใช้ได้ทุกแอป"
d.text(((W-d.textlength(t,font=f(28)))/2,y+110),t,font=f(28),fill=DIM)
y+=210

d.line([70,y,W-70,y],fill=(45,60,100),width=2)
for t,sz,c,off in [("Aloud  โดย torboshi  ·  instagram.com/torboshi",26,DIM,34),
                   ("พัฒนาต่อจาก WhisperApp ของ Gamezxz",23,(110,128,165),76)]:
    d.text(((W-d.textlength(t,font=f(sz)))/2,y+off),t,font=f(sz),fill=c)
im.crop((0,0,W,y+140)).save(OUT)
print(f"✅ {OUT}")
