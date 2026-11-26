# ezome — do'kon tizimi

Kiyim do'koni uchun: katalog, o'lchamlar, shtrix-kod va yorliqlar, kamera skaneri, kassa,
qarzlar, ishchilar hisoboti, admin «Bosh sahifa». Server: Supabase. Telefonga ilova bo'lib o'rnatiladi.

- Sayt — repo ildizida (`index.html`, `config.js`, `vendor/`, `icons/`, `chek/`).
- `manba/` — ilova manbasi, `build.py`, Supabase sxemasi va xodimlar serveri, Paynet serveri.

Ko'p do'konli: har kim «Yangi do'kon ochish» orqali ro'yxatdan o'tadi (Free — hech narsa qilib bo'lmaydi),
Pro/Premium ni sayt egasi beradi (Telegram: @perdeloto). Sozlash: `manba/supabase/README.md`.

## Android ilova (APK)

- `android/` — saytni ilova ichida ochadigan Android loyiha (kamera-skaner, chek rasmi, yorliq chop etish, zaxira saqlash).
- Har safar `android/` o'zgarsa, GitHub Actions APK ni yig'adi va `ezome.apk` qilib saytga qo'yadi:
  https://jaloliddinxolmaxmadov7-sudo.github.io/exo/ezome.apk
- `android/app/ezome-sideload.jks` — faqat telefonga qo'lda o'rnatish uchun kalit (ochiq). Play Market uchun alohida, maxfiy yuklash kaliti kerak bo'ladi.
