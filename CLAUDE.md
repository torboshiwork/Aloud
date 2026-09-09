# Aloud

macOS menu-bar dictation app (Swift) — กด Fn ค้างแล้วพูด → Groq STT → LLM แก้คำ → paste ลงแอปที่ใช้อยู่

Fork ของ [Gamezxz/WhisperApp](https://github.com/Gamezxz/WhisperApp) · rebrand เป็น "Aloud" ที่ v2.0.0

## สถานะปัจจุบัน (v2.0.0)

- **ชื่อ:** Aloud · bundle `Aloud.app` · executable `Aloud` · SPM target `Aloud` · bundle ID `com.torboshi.aloud`
- **ข้อมูลผู้ใช้:** `~/.aloud/` — key, `dictionary.txt`, `debug.log` (ทุกไฟล์ chmod 0600 โดยแอปเอง)
- **Hotkey default:** Fn, hold-to-talk · toggle mode = เคาะ 2 ครั้งเริ่ม เคาะ 1 ครั้งหยุด (`HotkeyManager.swift`)
- **Provider:** Groq เจ้าเดียว — key เดียวใช้ทั้ง STT (`whisper-large-v3`) + correction (`openai/gpt-oss-20b`)
  AI Correction **ปิดเป็นค่า default** — มันเรียบเรียงประโยคใหม่แทนที่จะแก้แค่คำผิด
- **ไมค์:** เปิดค้าง 60 วิหลังพูดจบแล้วปล่อย (`warmIdleSeconds` ใน `AudioRecorder.swift`)
  cold start ของ AVAudioEngine วัดได้ 372ms ถ้าปล่อยทันทีคำแรกจะหาย
- **Logo:** `assets/Aloud.icns` สร้างจาก `assets/Codex Image Sep 10, 2026, 02_27_31 AM.png` ด้วย sips + iconutil

## อย่าเปลี่ยนถ้าไม่จำเป็น

- **bundle ID** — TCC ผูกสิทธิ์ไมค์ + Accessibility กับ bundle ID + code signature เปลี่ยนเมื่อไหร่ผู้ใช้ต้องกดอนุญาตใหม่หมด
- **ชื่อโมเดล** `whisper-large-v3` และคำว่า Whisper ที่หมายถึงตัวโมเดล — ไม่ใช่ชื่อแอป อย่า rebrand ทับ

## Build & Release

- `./run.sh` — build + เปิดแอป (dev loop)
- `./make_app.sh` — build → sign → **ติดตั้งทับ `/Applications/Aloud.app` ให้เลย** (กัน 2 ก๊อปปี้คนละเวอร์ชัน)
- `./make_dmg.sh` — ต้องมี Developer ID + keychain profile `aloud-notary` ⇒ **ต้องสมัคร Apple Developer Program $99/ปี ซึ่งตอนนี้ยังไม่ได้สมัคร** ใช้ไม่ได้
- เซ็นด้วย "Apple Development" อยู่ — รันได้เฉพาะเครื่องนี้ แจกให้เครื่องอื่นต้องกด Open Anyway เอง
- อัปเวอร์ชันทุกครั้งที่แก้เสร็จ: `CFBundleShortVersionString` **และ** `CFBundleVersion` ให้ตรงกัน (Sparkle เทียบตัวหลัง)

## เว็บ (GitHub Pages)

- source ที่ `docs/` — ยังไม่ได้เปิด Pages
- `SUFeedURL` ชี้ `https://torboshiwork.github.io/Aloud/appcast.xml` · `docs/appcast.xml` **ตั้งใจให้ว่าง**
  (ของเดิมชี้ appcast ของ Gamezxz — กด Check for Updates แล้วบิลด์คนอื่นจะมาทับ)
- ลบ `SUPublicEDKey` ของเจ้าของเดิมออกแล้ว ถ้าจะแจก update เองต้อง gen คู่กุญแจใหม่

## ค้าง / ทำต่อได้

- **ยังไม่มี LICENSE** ทั้งใน repo นี้และต้นทาง ⇒ ตามกฎหมายคือสงวนสิทธิ์ทั้งหมด
  ใช้เองได้ แต่**แจกจ่ายสาธารณะยังไม่มีสิทธิ์** จนกว่าจะขอ LICENSE จาก Gamezxz
- `windows/` ยังเป็นแบรนด์เดิมทั้งโฟลเดอร์ (พอร์ต Windows แยก build/test ไม่ได้บนเครื่องนี้)
- ความแม่นภาษาไทย: Groq มีแค่ `whisper-large-v3` / `-turbo` ทางต่อคือ ElevenLabs Scribe (~$0.22/ชม.) ซึ่ง `STTProvider.swift` รองรับอยู่แล้ว แต่ dictionary จะเงียบเพราะยังไม่ได้ส่ง `keyterms`
