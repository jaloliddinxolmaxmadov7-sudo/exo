// ezome xodimlar serveri (ko'p do'konli).
//  - signup: yangi do'kon + uning admini (tarif: Free — sayt egasi Pro/Premium bermaguncha hech narsa qilib bo'lmaydi)
//  - create / update / disable: do'kon admini O'Z do'konidagi xodimlar bilan ishlaydi
//  - sa_*: faqat sayt egasi (ezp.superadmins + 2-bosqichli kod bilan kirgan)
// verify_jwt o'chiq: 'signup' tizimga kirmasdan chaqiriladi; qolgan amallar ichida tekshiriladi.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const email = (l: string) => String(l).toLowerCase() + '@ezome.app';
const pass = (c: string) => 'ezome-' + String(c);
const LOGIN = /^[a-z0-9_.-]{3,30}$/;
const TG = '@perdeloto';
const str = (v: unknown, n: number) => String(v ?? '').trim().slice(0, n);
const PLANS = ['free', 'pro', 'premium', 'lifetime'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST kerak' }, 405);
  const URL_ = Deno.env.get('SUPABASE_URL')!;
  const adm = createClient(URL_, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let b: Record<string, unknown> = {};
  try { b = await req.json(); } catch { return json({ error: 'JSON noto\'g\'ri' }, 400); }
  const action = String(b.action || '');

  // Do'kon + admin yaratish (signup va sayt egasi uchun umumiy)
  async function makeShop(o: { name: string; shop: string; phone: string; city: string; login: string; code: string; source: string; plan?: string; until?: string | null }) {
    const { data: u, error } = await adm.auth.admin.createUser({ email: email(o.login), password: pass(o.code), email_confirm: true });
    if (error || !u.user) return { error: /already/i.test(error?.message || '') ? 'Bu login band — boshqasini tanlang' : 'Yaratib bo\'lmadi' };
    const uid = u.user.id, t = Date.now();
    const { data: s, error: e1 } = await adm.from('shops').insert({
      name: o.shop, owner_name: o.name, phone: o.phone, city: o.city, source: o.source,
      plan: o.plan || 'free', plan_until: o.until || null, plan_changed_at: o.plan ? new Date().toISOString() : null,
    }).select('id').single();
    if (e1 || !s) { await adm.auth.admin.deleteUser(uid); return { error: 'Do\'kon yaratilmadi' }; }
    const { error: e2 } = await adm.from('docs').insert([
      { shop: s.id, col: 'users', id: uid, data: { name: o.name, login: o.login, role: 'admin', t } },
      { shop: s.id, col: 'meta', id: 'owner', data: { uid, t } },
      { shop: s.id, col: 'settings', id: 'main', data: { shop: o.shop, phone: o.phone } },
    ]);
    if (e2) { await adm.from('shops').delete().eq('id', s.id); await adm.auth.admin.deleteUser(uid); return { error: 'Saqlanmadi' }; }
    return { ok: true, uid, shop: s.id };
  }
  function checkNew(name: string, login: string, code: string) {
    if (name.length < 2) return 'Ismingizni yozing';
    if (!LOGIN.test(login)) return "Login 3–30 ta lotin harf, raqam, _ . - bo'lsin";
    if (code.length < 6) return 'Admin kodi kamida 6 belgi bo\'lsin';
    return '';
  }

  // --- Yangi do'kon ochish (har kim). 'setup' — eski ilova versiyasi uchun ---
  if (action === 'signup' || action === 'setup') {
    const name = str(b.name, 40), login = str(b.login, 30).toLowerCase(), code = String(b.code || '');
    const shop = str(b.shop, 60) || name, phone = str(b.phone, 30), city = str(b.city, 40);
    const bad = checkNew(name, login, code);
    if (bad) return json({ error: bad }, 400);
    if (shop.length < 2) return json({ error: "Do'kon nomini yozing" }, 400);
    // Spamdan himoya: 10 daqiqada 20 tadan ortiq yangi do'kon ochilmaydi
    const since = new Date(Date.now() - 10 * 60e3).toISOString();
    const { count } = await adm.from('shops').select('id', { count: 'exact', head: true }).eq('source', 'signup').gte('created_at', since);
    if ((count || 0) >= 20) return json({ error: 'Hozir juda ko\'p so\'rov. Birozdan keyin urinib ko\'ring.' }, 429);
    const r = await makeShop({ name, shop, phone, city, login, code, source: 'signup' });
    return r.error ? json({ error: r.error }, 400) : json(r);
  }

  // --- Qolgan amallar: tizimga kirgan bo'lish shart ---
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: who } = await adm.auth.getUser(jwt);
  if (!who?.user) return json({ error: 'Kirish kerak' }, 401);

  // --- Sayt egasi amallari ---
  if (action.startsWith('sa_')) {
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
    const asUser = createClient(URL_, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: 'Bearer ' + jwt } },
    });
    const { data: chk } = await asUser.rpc('sa_check');
    if (!chk?.super || !chk?.aal2) return json({ error: 'Ruxsat yo\'q' }, 403);
    const audit = (act: string, shop: string | null, detail: unknown) =>
      adm.from('sa_audit').insert({ uid: who.user.id, action: act, shop, detail });

    if (action === 'sa_create_shop') {
      const name = str(b.name, 40), login = str(b.login, 30).toLowerCase(), code = String(b.code || '');
      const shop = str(b.shop, 60) || name, phone = str(b.phone, 30), city = str(b.city, 40);
      const plan = PLANS.includes(String(b.plan)) ? String(b.plan) : 'free';
      const bad = checkNew(name, login, code);
      if (bad) return json({ error: bad }, 400);
      let until: string | null = null;
      if (plan === 'pro' || plan === 'premium') {
        const m = Math.min(120, Math.max(1, Number(b.months) || 1));
        const d = new Date(); d.setMonth(d.getMonth() + m); until = d.toISOString();
      }
      const r = await makeShop({ name, shop, phone, city, login, code, source: 'owner', plan, until });
      if (r.error) return json({ error: r.error }, 400);
      await audit('create_shop', r.shop!, { plan, until, login });
      return json(r);
    }

    if (action === 'sa_set_code') {
      const uid = String(b.uid || ''), code = String(b.code || '');
      const { data: t } = await adm.from('docs').select('shop,data').eq('col', 'users').eq('id', uid).maybeSingle();
      if (!t) return json({ error: 'Foydalanuvchi topilmadi' }, 404);
      if (code.length < (t.data?.role === 'admin' ? 6 : 4)) return json({ error: 'Kod juda qisqa' }, 400);
      const { error } = await adm.auth.admin.updateUserById(uid, { password: pass(code) });
      if (error) return json({ error: 'Almashtirib bo\'lmadi' }, 400);
      await audit('set_code', t.shop, { uid, login: t.data?.login });
      return json({ ok: true });
    }

    if (action === 'sa_user_active') {
      const uid = String(b.uid || ''), on = !!b.active;
      const { data: t } = await adm.from('docs').select('shop,data').eq('col', 'users').eq('id', uid).maybeSingle();
      if (!t) return json({ error: 'Foydalanuvchi topilmadi' }, 404);
      await adm.auth.admin.updateUserById(uid, { ban_duration: on ? 'none' : '876000h' });
      const data = { ...t.data, disabled: !on, ...(on ? {} : { disabledAt: Date.now() }) };
      if (on) delete (data as Record<string, unknown>).disabledAt;
      await adm.from('docs').update({ data }).eq('col', 'users').eq('id', uid);
      await audit(on ? 'user_on' : 'user_off', t.shop, { uid, login: t.data?.login });
      return json({ ok: true });
    }

    return json({ error: "Noma'lum amal" }, 400);
  }

  // --- Do'kon admini amallari: faqat o'z do'konida ---
  const { data: me } = await adm.from('docs').select('shop,data').eq('col', 'users').eq('id', who.user.id).maybeSingle();
  if (!me || me.data?.role !== 'admin' || me.data?.disabled) return json({ error: 'Faqat admin' }, 403);
  const { data: st } = await adm.rpc('shop_state', { p_shop: me.shop });

  if (action === 'create') {
    if (!st?.ok) return json({ error: `Tarifingiz faol emas. Pro yoki Premium uchun Telegram: ${TG}` }, 403);
    const name = str(b.name, 40), login = str(b.login, 30).toLowerCase(), code = String(b.code || '');
    const role = b.role === 'admin' ? 'admin' : 'worker';
    if (!name) return json({ error: 'Ismini yozing' }, 400);
    if (!LOGIN.test(login)) return json({ error: "Login 3–30 ta lotin harf, raqam, _ . - bo'lsin" }, 400);
    if (code.length < (role === 'admin' ? 6 : 4)) return json({ error: role === 'admin' ? 'Admin kodi kamida 6 belgi' : 'Ishchi kodi kamida 4 belgi' }, 400);
    const lim = st?.limits?.users;
    if (lim !== null && lim !== undefined && Number(st.users) >= Number(lim))
      return json({ error: `Tarif chegarasi: ${lim} ta xodim. Premium uchun Telegram: ${TG}` }, 403);
    const { data: u, error } = await adm.auth.admin.createUser({ email: email(login), password: pass(code), email_confirm: true });
    if (error || !u.user) return json({ error: /already/i.test(error?.message || '') ? 'Bu login band' : 'Xodimni yaratib bo\'lmadi' }, 400);
    const { error: e2 } = await adm.from('docs').insert({ shop: me.shop, col: 'users', id: u.user.id, data: { name, login, role, t: Date.now(), by: me.data?.name || '' } });
    if (e2) { await adm.auth.admin.deleteUser(u.user.id); return json({ error: 'Saqlanmadi' }, 500); }
    return json({ ok: true, uid: u.user.id });
  }

  const uid = String(b.uid || '');
  // Muhim: faqat SHU do'kon xodimi — boshqa do'kon odamiga tegib bo'lmaydi
  const { data: target } = await adm.from('docs').select('data').eq('shop', me.shop).eq('col', 'users').eq('id', uid).maybeSingle();
  if (!target) return json({ error: 'Xodim topilmadi' }, 404);

  if (action === 'update') {
    const upd: Record<string, unknown> = {};
    if (b.login !== undefined && b.login !== target.data?.login) {
      const login = String(b.login).trim().toLowerCase();
      if (!LOGIN.test(login)) return json({ error: 'Login noto\'g\'ri' }, 400);
      upd.email = email(login); upd.email_confirm = true;
    }
    if (b.code) {
      const min = target.data?.role === 'admin' ? 6 : 4;
      if (String(b.code).length < min) return json({ error: 'Kod juda qisqa' }, 400);
      upd.password = pass(String(b.code));
    }
    if (Object.keys(upd).length) {
      const { error } = await adm.auth.admin.updateUserById(uid, upd);
      if (error) return json({ error: /already/i.test(error.message) ? 'Bu login band' : 'Almashtirib bo\'lmadi' }, 400);
    }
    return json({ ok: true });
  }

  if (action === 'disable') {
    if (uid === who.user.id) return json({ error: "O'zingizni o'chira olmaysiz" }, 400);
    await adm.auth.admin.updateUserById(uid, { ban_duration: '876000h' });
    await adm.from('docs').update({ data: { ...target.data, disabled: true, disabledAt: Date.now() } }).eq('shop', me.shop).eq('col', 'users').eq('id', uid);
    return json({ ok: true });
  }

  return json({ error: "Noma'lum amal" }, 400);
});
