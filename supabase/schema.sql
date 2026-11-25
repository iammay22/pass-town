-- 及格鎮：樹洞留言牆
-- 用法：Supabase 後台左邊 SQL Editor → New query → 整份貼上 → Run

-- 1. 資料表
create table if not exists public.notes (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  uid uuid not null,
  name text not null check (char_length(name) between 1 and 12),
  title text not null default '' check (char_length(title) <= 20),
  text text not null check (char_length(text) between 1 and 40),
  pats int not null default 0,
  coffees int not null default 0
);

create table if not exists public.note_pats (
  note_id bigint references public.notes(id) on delete cascade,
  uid uuid not null,
  primary key (note_id, uid)
);

create table if not exists public.coffees (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  note_id bigint references public.notes(id) on delete cascade,
  to_uid uuid not null,
  from_uid uuid not null,
  from_name text not null,
  claimed boolean not null default false
);

-- 2. 權限：大家都能讀便利貼，其他寫入一律透過下面的函式，不能直接改表
alter table public.notes enable row level security;
alter table public.note_pats enable row level security;
alter table public.coffees enable row level security;

drop policy if exists "anyone can read notes" on public.notes;
create policy "anyone can read notes" on public.notes for select using (true);

-- 3. 髒話過濾（跟遊戲裡的清單一樣）
create or replace function public.clean_text(t text) returns text
language sql immutable as $$
  select regexp_replace(t, '(幹你|幹妳|幹爆|幹拎|幹林|靠北|靠杯|靠腰|白癡|白痴|智障|腦殘|低能|去死|媽的|他媽|你媽|尼瑪|三小|雞掰|機掰|雞巴|機巴|操你|肏|北七|垃圾人|賤人|賤貨|婊|破麻|廢物|屁眼|陰道|陰莖|做愛|強姦|支那|黑鬼|死gay|ㄍㄋㄋ|ㄎㄅ|ㄐㄅ|fuck|fuk|shit|bitch|cunt|dick|pussy|asshole|nigga|nigger|retard|porn|whore|slut|rape)', '＊＊', 'gi')
$$;

-- 4. 貼便利貼：每個人每天（台灣時間）一張
create or replace function public.post_note(p_name text, p_title text, p_text text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nid bigint;
begin
  if me is null then raise exception 'not signed in'; end if;
  if exists (
    select 1 from notes
    where uid = me and (created_at at time zone 'Asia/Taipei')::date = (now() at time zone 'Asia/Taipei')::date
  ) then raise exception 'one note per day'; end if;
  insert into notes (uid, name, title, text)
  values (me, left(p_name, 12), left(coalesce(p_title, ''), 20), clean_text(left(trim(p_text), 40)))
  returning id into nid;
  return nid;
end $$;

-- 5. 拍拍：每人每張只能拍一次
create or replace function public.pat_note(p_note bigint) returns int
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into note_pats (note_id, uid) values (p_note, me) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then update notes set pats = pats + 1 where id = p_note; end if;
  return n;
end $$;

-- 6. 請喝咖啡：記一筆，對方下次上線領
create or replace function public.send_coffee(p_note bigint, p_name text) returns int
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); target uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  select uid into target from notes where id = p_note;
  if target is null then raise exception 'note not found'; end if;
  if target = me then raise exception 'cannot buy yourself coffee'; end if;
  insert into coffees (note_id, to_uid, from_uid, from_name) values (p_note, target, me, left(p_name, 12));
  update notes set coffees = coffees + 1 where id = p_note;
  return 1;
end $$;

-- 7. 領咖啡錢：回傳 {n: 杯數, from: [誰請的]}
create or replace function public.claim_coffee() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); res json;
begin
  if me is null then return json_build_object('n', 0, 'from', '[]'::json); end if;
  with c as (
    update coffees set claimed = true where to_uid = me and not claimed returning from_name
  )
  select json_build_object('n', count(*), 'from', coalesce(json_agg(from_name), '[]'::json)) into res from c;
  return res;
end $$;

grant execute on function public.post_note(text, text, text) to authenticated;
grant execute on function public.pat_note(bigint) to authenticated;
grant execute on function public.send_coffee(bigint, text) to authenticated;
grant execute on function public.claim_coffee() to authenticated;

-- ============================================================
-- v18 新增：公告欄存款排行（只要多貼這一段，Run 一次）
-- ============================================================
create table if not exists public.money_board (
  uid uuid primary key,
  name text not null check (char_length(name) between 1 and 12),
  title text not null default '' check (char_length(title) <= 20),
  money bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.money_board enable row level security;
drop policy if exists "anyone can read board" on public.money_board;
create policy "anyone can read board" on public.money_board for select using (true);

-- 每個人只能更新自己那一列，金額限制在 -100 萬到 1000 萬之間
create or replace function public.set_money(p_name text, p_title text, p_money bigint) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into money_board (uid, name, title, money, updated_at)
  values (me, left(clean_text(coalesce(nullif(trim(p_name), ''), '同學')), 12), left(coalesce(p_title, ''), 20), greatest(-1000000, least(p_money, 10000000)), now())
  on conflict (uid) do update set name = excluded.name, title = excluded.title, money = excluded.money, updated_at = now();
end $$;
grant execute on function public.set_money(text, text, bigint) to authenticated;
