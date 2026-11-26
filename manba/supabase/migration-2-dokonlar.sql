-- ezome — 2-qadam: ko'p do'kon, tariflar (Free / Pro / Premium / butun umrlik) va sayt egasi (super-admin).
-- schema.sql dan KEYIN, Supabase → SQL Editor'da bir marta ishga tushiriladi. Qayta ishga tushirsa ham buzilmaydi.
-- Mavjud do'kon ma'lumotlari 'main' do'koniga o'tadi va unga butun umrlik tarif beriladi (hech narsa to'xtamaydi).
begin;

-- ===================== Do'konlar =====================
create table if not exists public.shops (
  id text primary key default replace(gen_random_uuid()::text, '-', ''),
  name text not null default '',
  owner_name text not null default '',
  phone text not null default '',
  city text not null default '',
  plan text not null default 'free' check (plan in ('free','pro','premium','lifetime')),
  plan_until timestamptz,
  plan_changed_at timestamptz,
  blocked boolean not null default false,
  note text not null default '',
  source text not null default 'signup',
  created_at timestamptz not null default now()
);
alter table public.shops enable row level security;          -- siyosat yo'q: faqat server funksiyalari o'qiydi/yozadi
revoke all on public.shops from public, anon, authenticated;

-- Sayt egasi(lar)i. Faqat SQL orqali qo'shiladi — saytda hech qayerda ko'rinmaydi.
create table if not exists ezp.superadmins (uid uuid primary key, added_at timestamptz not null default now());
revoke all on ezp.superadmins from public, anon, authenticated;

-- Sayt egasi amallari jurnali
create table if not exists public.sa_audit (
  id bigserial primary key, t timestamptz not null default now(), uid uuid, action text not null, shop text, detail jsonb
);
alter table public.sa_audit enable row level security;
revoke all on public.sa_audit from public, anon, authenticated;

-- ===================== docs → do'konlarga bo'linadi =====================
alter table public.docs add column if not exists shop text;

insert into public.shops (id, name, owner_name, plan, source)
select 'main',
       coalesce(nullif((select data->>'shop' from public.docs where col = 'settings' and id = 'main'), ''), 'ezome'),
       coalesce((select u.data->>'name' from public.docs m join public.docs u on u.col = 'users' and u.id = m.data->>'uid'
                 where m.col = 'meta' and m.id = 'owner'), ''),
       'lifetime', 'owner'
where exists (select 1 from public.docs where shop is null)
on conflict (id) do nothing;
update public.docs set shop = 'main' where shop is null;
alter table public.docs alter column shop set not null;

do $$ begin
  if exists (select 1 from pg_constraint where conname = 'docs_pkey'
             and pg_get_constraintdef(oid) = 'PRIMARY KEY (col, id)') then
    alter table public.docs drop constraint docs_pkey;
    alter table public.docs add constraint docs_pkey primary key (shop, col, id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'docs_shop_fk') then
    alter table public.docs add constraint docs_shop_fk foreign key (shop) references public.shops(id) on delete cascade;
  end if;
end $$;
drop index if exists public.docs_col_ts;
drop index if exists public.docs_col_uid_ts;
create index if not exists docs_shop_col_ts on public.docs (shop, col, ts desc);
create index if not exists docs_shop_col_uid_ts on public.docs (shop, col, uid, ts desc);
-- Bitta odam faqat bitta do'konda bo'ladi (boshqa do'kon admini birovni "o'g'irlab" ololmaydi)
create unique index if not exists docs_users_uid on public.docs (id) where col = 'users';

-- ===================== Yordamchi funksiyalar =====================
-- Tarif chegaralari — bitta joyda. null = cheksiz. users = admin bilan birga faol xodimlar soni.
-- debts = Qarzlar bo'limi (mijozlar va qarzlar) — faqat Premium va butun umrlikda.
create or replace function ezp.limits() returns jsonb language sql immutable set search_path = '' as $$
  select '{"free":{"users":0,"products":0,"debts":false},"pro":{"users":10,"products":null,"debts":false},"premium":{"users":null,"products":null,"debts":true},"lifetime":{"users":null,"products":null,"debts":true}}'::jsonb $$;

create or replace function ezp.my_shop() returns text language sql stable security definer set search_path = '' as $$
  select d.shop from public.docs d where d.col = 'users' and d.id = (select auth.uid())::text
    and coalesce((d.data->>'disabled')::boolean, false) = false $$;

create or replace function ezp.shop_ok(p_shop text) returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select not s.blocked and (s.plan = 'lifetime' or (s.plan in ('pro','premium') and s.plan_until > now()))
                   from public.shops s where s.id = p_shop), false) $$;

create or replace function ezp.my_ok() returns boolean language sql stable security definer set search_path = '' as $$
  select ezp.shop_ok(ezp.my_shop()) $$;

create or replace function ezp.is_super() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from ezp.superadmins a where a.uid = (select auth.uid()))
     and coalesce((select auth.jwt())->>'aal', '') = 'aal2' $$;

revoke all on function ezp.limits(), ezp.my_shop(), ezp.shop_ok(text), ezp.my_ok(), ezp.is_super() from public, anon;
grant execute on function ezp.limits(), ezp.my_shop(), ezp.shop_ok(text), ezp.my_ok(), ezp.is_super() to authenticated;
-- Xodimlar serveri (service_role) triggerlar ichidagi ezp funksiyalarini chaqira olishi uchun
grant usage on schema ezp to service_role;
grant execute on all functions in schema ezp to service_role;

-- ===================== Triggerlar =====================
create or replace function public.docs_fill() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then new.shop := old.shop;
  elsif new.shop is null then new.shop := ezp.my_shop(); end if;
  new.ts := coalesce(nullif(new.data->>'createdAt','')::bigint, nullif(new.data->>'t','')::bigint);
  new.uid := case new.col when 'sales' then new.data->>'sellerUid' when 'log' then new.data->>'uid'
    when 'reports' then new.data->>'uid' when 'paynet_orders' then new.data->>'by' else null end;
  new.updated_at := now(); return new;
end $$;

-- Tarif tekshiruvi: tovar soni chegarasi va Qarzlar bo'limi faqat Premium'da
create or replace function public.docs_limit() returns trigger language plpgsql security definer set search_path = '' as $$
declare s public.shops; lim int; n int;
begin
  if new.col not in ('products','customers','debts') then return new; end if;
  select * into s from public.shops where id = new.shop;
  if s.id is null then return new; end if;
  if not ezp.shop_ok(s.id) then
    raise exception 'Tarifingiz faol emas. Pro yoki Premium uchun Telegram: @perdeloto yoki @shamsiddinovichcc' using errcode = '42501';
  end if;
  if new.col in ('customers','debts') then
    if not coalesce((ezp.limits() -> s.plan ->> 'debts')::boolean, false) then
      raise exception 'Tarif: Qarzlar bo''limi faqat Premium tarifida. Telegram: @perdeloto yoki @shamsiddinovichcc' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if tg_op <> 'INSERT' then return new; end if;
  lim := (ezp.limits() -> s.plan ->> 'products')::int;
  if lim is null then return new; end if;
  select count(*) into n from public.docs where shop = new.shop and col = 'products';
  if n >= lim then
    raise exception 'Tarif chegarasi: % ta tovar. Premium uchun Telegram: @perdeloto yoki @shamsiddinovichcc', lim using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists docs_limit on public.docs;
create trigger docs_limit before insert or update on public.docs for each row execute function public.docs_limit();
revoke all on function public.docs_fill(), public.docs_limit() from public, anon, authenticated;

-- ===================== Ruxsat qoidalari (RLS) =====================
drop policy if exists docs_select on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;

create policy docs_select on public.docs for select to authenticated using (
  shop = (select ezp.my_shop()) and (case col
    when 'users' then (select ezp.is_admin()) or id = (select auth.uid())::text
    when 'sales' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'log' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'reports' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'paynet_orders' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'payments' then (select ezp.is_admin())
    when 'private' then false
    else (select ezp.is_active()) end));

-- Yozish: faqat tarifi faol do'konda (Free'da hech narsa yozib bo'lmaydi). Xodim faqat server orqali qo'shiladi.
create policy docs_insert on public.docs for insert to authenticated with check (
  shop = (select ezp.my_shop()) and (select ezp.my_ok()) and (case col
    when 'users' then false
    when 'settings' then (select ezp.is_admin())
    when 'products' then (select ezp.is_admin())
    when 'sales' then (select ezp.is_active()) and uid = (select auth.uid())::text and data->'paynet' is null and data->'ok' is null
    when 'log' then (select ezp.is_active()) and uid = (select auth.uid())::text
    when 'reports' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'customers' then (select ezp.is_active())
    when 'debts' then (select ezp.is_active())
    when 'paynet_orders' then (select ezp.is_active()) and uid = (select auth.uid())::text and data->>'status' = 'pending'
    else false end));

create policy docs_update on public.docs for update to authenticated
using (shop = (select ezp.my_shop()) and (select ezp.my_ok()) and (case col
    when 'products' then (select ezp.is_active())
    when 'reports' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'paynet_orders' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'payments' then false when 'private' then false when 'meta' then false
    else (select ezp.is_admin()) end))
with check (shop = (select ezp.my_shop()) and (select ezp.my_ok()) and (case col
    when 'products' then (select ezp.is_active())
    when 'reports' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'paynet_orders' then (select ezp.is_admin()) or ((select ezp.is_active()) and uid = (select auth.uid())::text)
    when 'payments' then false when 'private' then false when 'meta' then false
    else (select ezp.is_admin()) end));

create policy docs_delete on public.docs for delete to authenticated using (
  shop = (select ezp.my_shop()) and (select ezp.my_ok())
  and col not in ('payments','private','meta','users') and (select ezp.is_admin()));

-- ===================== Ilova funksiyalari (do'konga bog'langan) =====================
create or replace function public.put_doc(p_col text, p_id text, p_data jsonb) returns void language plpgsql security invoker set search_path = '' as $$
begin
  update public.docs set data = p_data where shop = ezp.my_shop() and col = p_col and id = p_id;
  if not found then insert into public.docs (col, id, data) values (p_col, p_id, p_data); end if;
end $$;

create or replace function public.next_no() returns integer language plpgsql security definer set search_path = '' as $$
declare n integer; s text := ezp.my_shop();
begin
  if s is null or not ezp.is_active() or not ezp.shop_ok(s) then raise exception 'Ruxsat yo''q' using errcode = '42501'; end if;
  insert into public.docs (shop, col, id, data) values (s, 'meta', 'counter', '{"no":1001}')
  on conflict (shop, col, id) do update set data = jsonb_build_object('no', coalesce((public.docs.data->>'no')::int, 1000) + 1)
  returning (data->>'no')::int into n;
  return n;
end $$;

create or replace function public.set_counter(p_no integer) returns void language plpgsql security definer set search_path = '' as $$
declare s text := ezp.my_shop();
begin
  if s is null or not ezp.is_admin() or not ezp.shop_ok(s) then raise exception 'Ruxsat yo''q' using errcode = '42501'; end if;
  insert into public.docs (shop, col, id, data) values (s, 'meta', 'counter', jsonb_build_object('no', p_no))
  on conflict (shop, col, id) do update set data = jsonb_build_object('no', greatest(p_no, coalesce((public.docs.data->>'no')::int, 0)));
end $$;

-- Do'kon o'z tarifini ko'radi. "Butun umrlik" so'zi hech qachon chiqmaydi — u Premium (muddatsiz) bo'lib ko'rinadi.
create or replace function public.my_shop_info() returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name,
    'plan', case when s.plan = 'lifetime' then 'premium' else s.plan end,
    'until', case when s.plan = 'lifetime' then null else s.plan_until end,
    'ok', ezp.shop_ok(s.id), 'blocked', s.blocked,
    'limits', ezp.limits() -> s.plan)
  from public.shops s where s.id = ezp.my_shop() $$;

-- Xodimlar serveri uchun (faqat service_role)
create or replace function public.shop_state(p_shop text) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', ezp.shop_ok(s.id), 'plan', s.plan, 'limits', ezp.limits() -> s.plan,
    'users', (select count(*) from public.docs d where d.shop = s.id and d.col = 'users' and coalesce((d.data->>'disabled')::boolean, false) = false))
  from public.shops s where s.id = p_shop $$;

revoke all on function public.next_no(), public.set_counter(integer), public.put_doc(text, text, jsonb), public.my_shop_info(), public.shop_state(text) from public, anon;
grant execute on function public.next_no(), public.set_counter(integer), public.put_doc(text, text, jsonb), public.my_shop_info() to authenticated;
revoke all on function public.shop_state(text) from authenticated;
grant execute on function public.shop_state(text) to service_role;
grant all on public.shops, public.sa_audit to service_role;
grant usage, select on sequence public.sa_audit_id_seq to service_role;

-- ===================== Rasmlar: boshqa do'kon rasmiga tegib bo'lmaydi =====================
drop policy if exists img_insert on storage.objects;
drop policy if exists img_delete on storage.objects;
create policy img_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'img' and (storage.foldername(name))[1] = (select auth.uid())::text and (select ezp.is_active()) and (select ezp.my_ok()));
create policy img_delete on storage.objects for delete to authenticated using (
  bucket_id = 'img' and (select ezp.is_admin()) and exists (
    select 1 from public.docs d where d.col = 'users' and d.id = (storage.foldername(name))[1] and d.shop = (select ezp.my_shop())));

-- ===================== Sayt egasi (super-admin) funksiyalari =====================
-- Har biri: (1) ezp.superadmins ro'yxatida bo'lish VA (2) 2-bosqichli kod (TOTP) bilan kirgan bo'lish shart.
create or replace function public.sa_check() returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('super', exists (select 1 from ezp.superadmins a where a.uid = (select auth.uid())),
                            'aal2', coalesce((select auth.jwt())->>'aal', '') = 'aal2') $$;

create or replace function ezp.sa_need() returns void language plpgsql stable security definer set search_path = '' as $$
begin if not ezp.is_super() then raise exception 'Ruxsat yo''q' using errcode = '42501'; end if; end $$;

create or replace function public.sa_overview() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform ezp.sa_need();
  return jsonb_build_object(
    'shops', (select count(*) from public.shops),
    'shops_ok', (select count(*) from public.shops s where ezp.shop_ok(s.id)),
    'plans', (select coalesce(jsonb_object_agg(plan, n), '{}') from (select plan, count(*) n from public.shops group by plan) x),
    'new_7d', (select count(*) from public.shops where created_at > now() - interval '7 days'),
    'new_30d', (select count(*) from public.shops where created_at > now() - interval '30 days'),
    'expiring_7d', (select count(*) from public.shops where plan in ('pro','premium') and plan_until between now() and now() + interval '7 days'),
    'expired', (select count(*) from public.shops where plan in ('pro','premium') and plan_until <= now()),
    'blocked', (select count(*) from public.shops where blocked),
    'users', (select count(*) from public.docs where col = 'users'),
    'users_active', (select count(*) from public.docs where col = 'users' and coalesce((data->>'disabled')::boolean, false) = false),
    'auth_users', (select count(*) from auth.users),
    'signin_24h', (select count(*) from auth.users where last_sign_in_at > now() - interval '24 hours'),
    'active_24h', (select count(distinct shop) from public.docs where updated_at > now() - interval '24 hours'),
    'db_bytes', pg_database_size(current_database()),
    'docs_bytes', pg_total_relation_size('public.docs'),
    'docs_rows', (select count(*) from public.docs),
    'storage_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects),
    'storage_files', (select count(*) from storage.objects));
end $$;

create or replace function public.sa_shops() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform ezp.sa_need();
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]') from (
    select s.*, ezp.shop_ok(s.id) as ok,
      (select count(*) from public.docs d where d.shop = s.id and d.col = 'users' and coalesce((d.data->>'disabled')::boolean, false) = false) as users,
      (select count(*) from public.docs d where d.shop = s.id and d.col = 'products') as products,
      (select count(*) from public.docs d where d.shop = s.id and d.col = 'sales') as sales,
      (select coalesce(sum(pg_column_size(d.*)), 0) from public.docs d where d.shop = s.id) as data_bytes,
      (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o
        where o.bucket_id = 'img' and (storage.foldername(o.name))[1] in (select d.id from public.docs d where d.shop = s.id and d.col = 'users')) as img_bytes,
      (select max(d.updated_at) from public.docs d where d.shop = s.id) as last_active,
      (select coalesce(jsonb_agg(jsonb_build_object('uid', d.id, 'name', d.data->>'name', 'login', d.data->>'login')), '[]')
        from public.docs d where d.shop = s.id and d.col = 'users' and d.data->>'role' = 'admin'
          and coalesce((d.data->>'disabled')::boolean, false) = false) as admins
    from public.shops s) x);
end $$;

create or replace function public.sa_users() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform ezp.sa_need();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'uid', d.id, 'name', d.data->>'name', 'login', d.data->>'login', 'role', d.data->>'role',
      'disabled', coalesce((d.data->>'disabled')::boolean, false), 'shop', d.shop, 'shop_name', s.name, 'plan', s.plan,
      'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at) order by u.created_at desc nulls last), '[]')
    from public.docs d join public.shops s on s.id = d.shop left join auth.users u on u.id::text = d.id
    where d.col = 'users');
end $$;

-- Tarif berish. p_months berilsa: muddat bugundan (yoki shu tarif hali tugamagan bo'lsa — tugash kunidan) uzaytiriladi.
create or replace function public.sa_set_plan(p_shop text, p_plan text, p_months integer default null, p_until timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.shops; u timestamptz;
begin
  perform ezp.sa_need();
  if p_plan not in ('free','pro','premium','lifetime') then raise exception 'Tarif noto''g''ri'; end if;
  select * into s from public.shops where id = p_shop for update;
  if s.id is null then raise exception 'Do''kon topilmadi'; end if;
  if p_plan in ('pro','premium') then
    if p_months is not null then
      if p_months < 1 or p_months > 120 then raise exception 'Oy soni 1–120'; end if;
      u := (case when s.plan = p_plan and s.plan_until > now() then s.plan_until else now() end) + make_interval(months => p_months);
    else u := p_until; end if;
    if u is null or u <= now() then raise exception 'Tugash sanasi kelajakda bo''lsin'; end if;
  else u := null; end if;
  update public.shops set plan = p_plan, plan_until = u, plan_changed_at = now() where id = p_shop returning * into s;
  insert into public.sa_audit (uid, action, shop, detail) values ((select auth.uid()), 'plan', p_shop, jsonb_build_object('plan', p_plan, 'until', u, 'months', p_months));
  return to_jsonb(s);
end $$;

create or replace function public.sa_update_shop(p_shop text, p_name text default null, p_owner_name text default null, p_phone text default null,
  p_city text default null, p_note text default null, p_blocked boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.shops;
begin
  perform ezp.sa_need();
  update public.shops set name = coalesce(left(p_name, 80), name), owner_name = coalesce(left(p_owner_name, 60), owner_name),
    phone = coalesce(left(p_phone, 40), phone), city = coalesce(left(p_city, 60), city), note = coalesce(left(p_note, 1000), note),
    blocked = coalesce(p_blocked, blocked)
  where id = p_shop returning * into s;
  if s.id is null then raise exception 'Do''kon topilmadi'; end if;
  insert into public.sa_audit (uid, action, shop, detail) values ((select auth.uid()), case when p_blocked is true then 'block' when p_blocked is false then 'unblock' else 'edit' end, p_shop, null);
  return to_jsonb(s);
end $$;

create or replace function public.sa_audit_list() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform ezp.sa_need();
  return (select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('shop_name', s.name) order by a.id desc), '[]')
    from (select * from public.sa_audit order by id desc limit 100) a left join public.shops s on s.id = a.shop);
end $$;

revoke all on function public.sa_check(), ezp.sa_need(), public.sa_overview(), public.sa_shops(), public.sa_users(),
  public.sa_set_plan(text, text, integer, timestamptz), public.sa_update_shop(text, text, text, text, text, text, boolean),
  public.sa_audit_list() from public, anon;
grant execute on function public.sa_check(), ezp.sa_need(), public.sa_overview(), public.sa_shops(), public.sa_users(),
  public.sa_set_plan(text, text, integer, timestamptz), public.sa_update_shop(text, text, text, text, text, text, boolean),
  public.sa_audit_list() to authenticated;

commit;
