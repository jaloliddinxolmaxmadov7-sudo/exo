# ezome — Supabase server qismi

Loyiha: `nyrtswxdrxsycubkhpiw` (eu-central-1, bepul tarif).

- `schema.sql` — `docs` jadvali, ruxsat qoidalari (RLS), real vaqt, rasmlar papkasi (`img`), sotuv raqami hisoblagichi.
- `migration-2-dokonlar.sql` — **ko'p do'kon**, tariflar (Free / Pro / Premium / butun umrlik) va sayt egasi funksiyalari.
- `functions/staff/index.ts` — xodimlar serveri: yangi do'kon ochish, xodim qo'shish, login/kod almashtirish, o'chirish, sayt egasi amallari.

## Ishga tushirish tartibi (bir marta, aynan shu tartibda)

1. **SQL**: Supabase → SQL Editor → `migration-2-dokonlar.sql` ni to'liq qo'yib **Run**.
   Hozirgi do'kon ma'lumotlari `main` do'koniga o'tadi va unga butun umrlik tarif beriladi — hech narsa to'xtamaydi.
2. **Xodimlar serveri**: Supabase → Edge Functions → `staff` → kodni `functions/staff/index.ts` bilan almashtirib **Deploy**
   (yoki: `supabase functions deploy staff --no-verify-jwt`). 1-qadamdan keyin darhol qiling.
3. **Saytni yangilash**: GitHub'dagi Pull request'ni `main` ga qo'shing (merge).
4. **Ochiq ro'yxatdan o'tishni o'chiring**: Authentication → Sign In / Providers → *Allow new users to sign up* → **OFF**.
   (Do'konlar baribir sayt orqali ochiladi — server o'zi yaratadi. Bu begonalar to'g'ridan-to'g'ri hisob ochishini to'sadi.)
5. **2-bosqichli kod (TOTP)** yoqilganini tekshiring: Authentication → Multi-Factor → TOTP — *Enabled* (odatda yoqiq).

## Sayt egasi (siz) hisobini yaratish

1. Authentication → Users → **Add user** → o'z emailingiz va **kuchli parol** (kamida 14 belgi). *Auto confirm* belgilansin.
2. Boshqaruv paneliga kiring: `https://jaloliddinxolmaxmadov7-sudo.github.io/exo/ega-9f3k7q/`
   Email + parol → telefoningizga Google Authenticator o'rnatib QR'ni skanerlang → 6 xonali kod. Panel hozircha "ruxsat yo'q" deydi — bu to'g'ri.
3. SQL Editor'da o'zingizni sayt egasi qiling (emailni o'zingiznikiga almashtiring):
   ```sql
   insert into ezp.superadmins (uid) select id from auth.users where email = 'SIZNING@EMAIL.COM';
   ```
4. Panelga qayta kiring — tayyor.

Tartib muhim: avval 2-bosqichli kodni o'zingiz yoqasiz, keyin ro'yxatga qo'shasiz. Shunda parolingizni kimdir bilib olsa ham, telefoningizsiz kira olmaydi.

## Ruxsatlar qisqacha

- Har do'kon faqat **o'z** ma'lumotini ko'radi; boshqa do'kon admini sizning do'koningizga, xodimlaringizga, rasmlaringizga tega olmaydi.
- **Free** — sinov ko'rinishi: ilova Premium'dek to'liq ochiladi, ichida namuna tovarlar, sotuvlar, xodimlar va qarzlar bor (bazaga yozilmaydi, faqat ekranda).
  Hech narsa saqlanmaydi: ilovada ham, bazada ham to'silgan. Tepada "Sinov ko'rinishi" paneli va Telegram havolalari (1-admin @perdeloto, 2-admin @shamsiddinovichcc) turadi.
  Pro/Premium berilgach, 1 daqiqa ichida o'zi haqiqiy (bo'sh) do'konga o'tadi.
- **Pro** — 150 000 so'm/oy: kassa, katalog, shtrix-kod, 10 tagacha xodim, cheksiz tovar, hisobotlar. **Qarzlar bo'limi yo'q.**
- **Premium** — 300 000 so'm/oy va **butun umrlik**: hammasi cheksiz + Qarzlar (qarzga sotish, mijozlar, muddat eslatmasi).
- **Butun umrlik** saytda hech qayerda yozilmaydi — u do'konga "Premium · Muddatsiz" bo'lib ko'rinadi. Uni faqat siz paneldan berasiz.
- Muddat tugasa — do'kon avtomatik Free holatiga tushadi (ma'lumotlari saqlanadi), uzaytirsangiz darhol ochiladi.
- Sayt egasi funksiyalari (`sa_*`) faqat `ezp.superadmins` dagi va 2-bosqichli kod bilan kirgan odamga ishlaydi. Har bir amal `sa_audit` jurnaliga yoziladi.
- Admin hammasini ko'radi va o'zgartiradi; ishchi faqat o'z sotuvi, tarixi va hisobotini ko'radi; tovarning faqat qoldig'ini o'zgartira oladi.
