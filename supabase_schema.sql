-- ════════════════════════════════════════════
--  ENOSCRIGNO — Schema Supabase
--  Esegui questo script nel SQL Editor di Supabase:
--  supabase.com → progetto → SQL Editor → New query → incolla → Run
-- ════════════════════════════════════════════

-- ── PROFILES (dati sommelier, estende auth.users) ──
create table if not exists public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  full_name          text,
  assoc              text,                     -- AIS | FISAR | ONAV | FIS | ''
  card               text,                     -- numero tessera
  delegazione        text,                     -- delegazione da menu
  delegazione_custom text,                     -- delegazione testo libero
  ai_scan_enabled    boolean not null default false,  -- accesso alla scansione AI (funzione premium)
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

-- ── WINES ──
create table if not exists public.wines (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,

  -- identità
  name          text not null,
  producer      text,
  vintage       integer,
  type          text,             -- Rosso | Bianco | Rosato | Spumante | Dolce | Passito | Altro
  doc           text,
  grapes        text,

  -- provenienza
  region        text,
  province      text,             -- solo Italia (es. 'Cuneo' per il Barolo)
  visibility    boolean not null default true,  -- se visibile nella futura sezione Network
  country       text default 'Italia',

  -- tecnico
  abv           numeric(4,1),
  format        text default '750 ml',

  -- cantina
  price         numeric(8,2),
  qty           integer default 1,
  date          date,             -- data acquisto
  shop          text,             -- luogo acquisto (dettaglio libero)
  shop_category text,             -- Cantina | Enoteca | Evento | Web | Supermercato | Regalo | Altro
  drink         text,             -- finestra consumo

  -- degustazione
  tasting_date  date,
  tasting_place text,
  pairing       text,             -- abbinamenti cibo (chip predefiniti + testo libero, separati da virgola)
  deg_schema    text default 'free',   -- ais | fisar | free

  -- scheda AIS
  ais_params    jsonb,
  ais_score     integer,
  olf_note      text,
  gust_note     text,

  -- scheda FISAR
  fisar_params  jsonb,
  fisar_score   integer,
  fp_note       text,

  -- valutazione libera
  score         integer,
  notes         text,
  tags          text,

  -- immagini (base64 o URL storage)
  front_img     text,
  back_img      text,

  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- ── INDICI ──
create index if not exists wines_user_id_idx on public.wines(user_id);
create index if not exists wines_created_at_idx on public.wines(user_id, created_at desc);

-- ── ROW LEVEL SECURITY ──
-- Ogni utente vede e modifica SOLO i propri dati.

alter table public.profiles enable row level security;
alter table public.wines     enable row level security;

-- Profiles: l'utente può leggere e scrivere solo il proprio profilo
create policy "profiles: own read"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles: own insert"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "profiles: own update"
  on public.profiles for update
  using (auth.uid() = id);

-- Wines: l'utente può leggere e modificare solo i propri vini
create policy "wines: own read"
  on public.wines for select
  using (auth.uid() = user_id);

create policy "wines: own insert"
  on public.wines for insert
  with check (auth.uid() = user_id);

create policy "wines: own update"
  on public.wines for update
  using (auth.uid() = user_id);

create policy "wines: own delete"
  on public.wines for delete
  using (auth.uid() = user_id);

-- ── TRIGGER: aggiorna updated_at automaticamente ──
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger wines_updated_at
  before update on public.wines
  for each row execute function public.set_updated_at();

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ── TRIGGER: crea automaticamente il profilo alla registrazione ──
-- Questo è FONDAMENTALE: se la conferma email è attiva, il client
-- non ha ancora una sessione autenticata subito dopo la registrazione,
-- quindi un salvataggio del profilo fatto dal browser verrebbe bloccato
-- dalla Row Level Security. Questo trigger gira lato server con
-- privilegi elevati (SECURITY DEFINER) e quindi funziona sempre,
-- indipendentemente dalla conferma email.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_cellar_id uuid;
begin
  insert into public.profiles (id, full_name, assoc, card, delegazione, delegazione_custom)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'assoc', ''),
    coalesce(new.raw_user_meta_data->>'card', ''),
    '', ''
  )
  on conflict (id) do nothing;

  -- Ogni utente ha sempre una cantina "principale" propria, creata
  -- automaticamente: condividerla con altri significa semplicemente
  -- invitarli qui dentro, senza bisogno di un concetto separato di
  -- "cantina personale" vs "cantina condivisa".
  insert into public.cellars (name, owner_id, invite_code, is_default)
  values ('La mia cantina', new.id, upper(substr(md5(random()::text), 1, 6)), true)
  returning id into new_cellar_id;

  insert into public.cellar_members (cellar_id, user_id, status)
  values (new_cellar_id, new.id, 'accepted');

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ════════════════════════════════════════════
-- FATTO! Ora vai in Authentication → Email Templates
-- e personalizza il template di conferma email se vuoi.
-- ════════════════════════════════════════════

-- ════════════════════════════════════════════
-- MIGRAZIONE — se il database esiste già (tabelle già create in
-- precedenza), esegui SOLO questa riga per aggiungere il nuovo
-- campo "abbinamento cibo" senza perdere i dati esistenti:
-- ════════════════════════════════════════════
alter table public.wines add column if not exists pairing text;

-- ════════════════════════════════════════════
-- SCAN USAGE — contatore per limitare la scansione etichette AI
-- Tiene traccia di quante scansioni sono state fatte, per utente
-- e in totale, in ogni mese ('2026-07' ecc). Scritto SOLO dalla
-- Edge Function tramite la service role key: nessun accesso diretto
-- dal client, quindi RLS resta abilitata senza policy (deny-all).
-- ════════════════════════════════════════════
create table if not exists public.scan_usage (
  scope  text not null,   -- 'global' oppure lo user_id del sommelier
  period text not null,   -- mese in formato 'YYYY-MM'
  count  integer not null default 0,
  updated_at timestamptz default now(),
  primary key (scope, period)
);
alter table public.scan_usage enable row level security;
-- Nessuna policy = nessun accesso dal client (anon/authenticated).
-- Solo la Edge Function, che usa la service role key, può leggere/scrivere.

-- ════════════════════════════════════════════
-- AI SCAN — flag premium per abilitare la scansione etichette
-- Se il database esiste già, esegui questa riga per aggiungere la
-- colonna senza perdere i dati esistenti. Di default è FALSE per
-- tutti (anche gli utenti già registrati).
-- ════════════════════════════════════════════
alter table public.profiles add column if not exists ai_scan_enabled boolean not null default false;

-- Poi abilita la scansione AI solo per il tuo account, sostituendo
-- l'email con la tua:
-- update public.profiles set ai_scan_enabled = true
--   where id = (select id from auth.users where email = 'TUA_EMAIL@esempio.it');

-- ════════════════════════════════════════════
-- PROVINCIA — se il database esiste già, esegui questa riga per
-- aggiungere il campo provincia (rilevante solo per l'Italia)
-- ════════════════════════════════════════════
alter table public.wines add column if not exists province text;

-- ════════════════════════════════════════════
-- CATEGORIA ACQUISTO — se il database esiste già, esegui questa riga
-- per aggiungere il campo di classificazione del luogo di acquisto
-- ════════════════════════════════════════════
alter table public.wines add column if not exists shop_category text;

-- ════════════════════════════════════════════
-- VISIBILITÀ NETWORK — se il database esiste già, esegui questa riga
-- per aggiungere il campo che determina se una scheda vino potrà
-- essere vista da altri utenti nella futura sezione Network.
-- Default TRUE per tutti i vini già esistenti.
-- ════════════════════════════════════════════
alter table public.wines add column if not exists visibility boolean not null default true;

-- ════════════════════════════════════════════
-- NETWORK — fondamenta per la parte condivisa
-- ════════════════════════════════════════════

-- 1) Profilo: immagine personale + interruttore "profilo pubblico"
--    Un profilo NON pubblico non è mai ricercabile da altri utenti,
--    indipendentemente da quanti vini abbia impostati come visibili.
alter table public.profiles add column if not exists avatar_base64 text;
alter table public.profiles add column if not exists is_public boolean not null default false;

-- 2) Tabella follow — richieste di seguire un altro utente
create table if not exists public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  followee_id uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'pending',  -- 'pending' | 'accepted'
  created_at  timestamptz default now(),
  primary key (follower_id, followee_id),
  constraint no_self_follow check (follower_id <> followee_id)
);
alter table public.follows enable row level security;

create policy "follows: vedo le mie richieste (inviate o ricevute)"
  on public.follows for select
  using (auth.uid() = follower_id or auth.uid() = followee_id);

create policy "follows: posso creare solo richieste mie"
  on public.follows for insert
  with check (auth.uid() = follower_id);

create policy "follows: accetto/rifiuto se sono il destinatario, annullo se il mittente"
  on public.follows for update
  using (auth.uid() = followee_id or auth.uid() = follower_id);

create policy "follows: elimino una relazione che mi coinvolge"
  on public.follows for delete
  using (auth.uid() = follower_id or auth.uid() = followee_id);

-- 3) Profili pubblici ricercabili da chiunque sia autenticato
--    (si aggiunge alla policy esistente "profiles: own read" — un
--    utente vede sempre il proprio profilo, e in più quelli pubblici)
create policy "profiles: profili pubblici visibili a tutti"
  on public.profiles for select
  using (is_public = true);

-- 4) Vini visibili nel feed Network: solo se il proprietario è
--    seguito con richiesta accettata E il singolo vino è impostato
--    come visibile (colonna wines.visibility)
create policy "wines: visibili nel network se seguo l'utente e il vino è pubblico"
  on public.wines for select
  using (
    visibility = true
    and exists (
      select 1 from public.follows f
      where f.follower_id = auth.uid()
        and f.followee_id = wines.user_id
        and f.status = 'accepted'
    )
  );

-- ════════════════════════════════════════════
-- FISAR — scheda descrittiva (alternativa a quella a punteggio)
-- ════════════════════════════════════════════
alter table public.profiles add column if not exists fisar_method text not null default 'punteggio'; -- 'punteggio' | 'descrittiva'
alter table public.wines add column if not exists fisar_desc_params jsonb;

-- ════════════════════════════════════════════
-- CANTINE CONDIVISE — più utenti possono possedere insieme la
-- stessa cantina (es. familiari, colleghi). Tutti i membri sono
-- alla pari: chiunque può aggiungere, modificare ed eliminare
-- i vini della cantina condivisa.
-- ════════════════════════════════════════════

create table if not exists public.cellars (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  invite_code text not null unique,
  is_default  boolean not null default false,  -- la cantina "principale" creata automaticamente alla registrazione
  created_at  timestamptz default now()
);
alter table public.cellars enable row level security;

create table if not exists public.cellar_members (
  cellar_id   uuid not null references public.cellars(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'pending',  -- 'pending' | 'accepted'
  invited_by  uuid references auth.users(id),
  created_at  timestamptz default now(),
  primary key (cellar_id, user_id)
);
alter table public.cellar_members enable row level security;

-- Ogni vino può appartenere a una cantina condivisa (cellar_id) invece
-- che essere solo personale (cellar_id null = comportamento di sempre)
alter table public.wines add column if not exists cellar_id uuid references public.cellars(id) on delete set null;

-- ── Policy: cellars ──
create policy "cellars: vedo le cantine di cui sono owner o membro accettato"
  on public.cellars for select
  using (
    auth.uid() = owner_id
    or public.is_cellar_member(cellars.id, auth.uid())
  );

create policy "cellars: chiunque autenticato può crearne una (diventandone owner)"
  on public.cellars for insert
  with check (auth.uid() = owner_id);

create policy "cellars: solo owner modifica (nome, rigenera codice)"
  on public.cellars for update
  using (auth.uid() = owner_id);

create policy "cellars: solo owner elimina la cantina condivisa"
  on public.cellars for delete
  using (auth.uid() = owner_id and is_default = false);

-- ── Policy: cellar_members ──
-- Funzione "di sistema" per controllare l'appartenenza a una cantina
-- senza innescare una nuova valutazione delle policy su cellar_members
-- (altrimenti si genera una ricorsione infinita, dato che la policy
-- di cellar_members deve poter controllare... cellar_members stessa)
create or replace function public.is_cellar_member(p_cellar_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.cellar_members
    where cellar_id = p_cellar_id and user_id = p_user_id and status = 'accepted'
  );
$$;

create policy "cellar_members: vedo le mie righe, quelle delle cantine che possiedo, o dei membri se sono accettato"
  on public.cellar_members for select
  using (
    auth.uid() = user_id
    or exists (select 1 from public.cellars c where c.id = cellar_members.cellar_id and c.owner_id = auth.uid())
    or public.is_cellar_member(cellar_members.cellar_id, auth.uid())
  );

create policy "cellar_members: mi unisco da solo (codice) o vengo invitato da un membro/owner"
  on public.cellar_members for insert
  with check (
    auth.uid() = user_id
    or exists (select 1 from public.cellars c where c.id = cellar_members.cellar_id and c.owner_id = auth.uid())
    or public.is_cellar_member(cellar_members.cellar_id, auth.uid())
  );

create policy "cellar_members: accetto il mio invito"
  on public.cellar_members for update
  using (auth.uid() = user_id);

create policy "cellar_members: esco da solo, oppure l'owner rimuove un membro"
  on public.cellar_members for delete
  using (
    (auth.uid() = user_id and not exists (
      select 1 from public.cellars c where c.id = cellar_members.cellar_id and c.owner_id = auth.uid() and c.is_default = true
    ))
    or exists (select 1 from public.cellars c where c.id = cellar_members.cellar_id and c.owner_id = auth.uid())
  );

-- ── Policy: wines — accesso paritario per tutti i membri accettati ──
create policy "wines: membri accettati vedono i vini della cantina condivisa"
  on public.wines for select
  using (
    cellar_id is not null
    and public.is_cellar_member(wines.cellar_id, auth.uid())
  );

create policy "wines: membri accettati aggiungono vini alla cantina condivisa"
  on public.wines for insert
  with check (
    cellar_id is not null
    and public.is_cellar_member(wines.cellar_id, auth.uid())
  );

create policy "wines: membri accettati modificano i vini della cantina condivisa"
  on public.wines for update
  using (
    cellar_id is not null
    and public.is_cellar_member(wines.cellar_id, auth.uid())
  );

create policy "wines: membri accettati eliminano i vini della cantina condivisa"
  on public.wines for delete
  using (
    cellar_id is not null
    and public.is_cellar_member(wines.cellar_id, auth.uid())
  );

-- ════════════════════════════════════════════
-- MIGRAZIONE — unifica 'cantina personale' e 'cantine condivise'
-- in un unico modello: ogni utente ha sempre una cantina 'principale'
-- reale (is_default = true), condivisibile come tutte le altre.
-- Da eseguire UNA SOLA VOLTA sul database già esistente.
-- ════════════════════════════════════════════
alter table public.cellars add column if not exists is_default boolean not null default false;

-- 1) Crea la cantina principale per ogni utente che non ne ha ancora una
insert into public.cellars (name, owner_id, invite_code, is_default)
select 'La mia cantina', u.id, upper(substr(md5(random()::text || u.id::text), 1, 6)), true
from auth.users u
where not exists (
  select 1 from public.cellars c where c.owner_id = u.id and c.is_default = true
);

-- 2) Iscrive ogni utente come membro accettato della propria cantina principale
insert into public.cellar_members (cellar_id, user_id, status)
select c.id, c.owner_id, 'accepted'
from public.cellars c
where c.is_default = true
on conflict (cellar_id, user_id) do nothing;

-- 3) Sposta i vini "personali" (cellar_id null) di ciascun utente
--    nella sua nuova cantina principale
update public.wines w
set cellar_id = c.id
from public.cellars c
where c.owner_id = w.user_id
  and c.is_default = true
  and w.cellar_id is null;

-- Aggiorna anche la policy di uscita per impedire al proprietario di
-- uscire per errore dalla propria cantina principale
drop policy if exists "cellar_members: esco da solo, oppure l'owner rimuove un membro" on public.cellar_members;
create policy "cellar_members: esco da solo, oppure l'owner rimuove un membro"
  on public.cellar_members for delete
  using (
    (auth.uid() = user_id and not exists (
      select 1 from public.cellars c where c.id = cellar_members.cellar_id and c.owner_id = auth.uid() and c.is_default = true
    ))
    or exists (select 1 from public.cellars c where c.id = cellar_members.cellar_id and c.owner_id = auth.uid())
  );

-- Aggiorna anche la policy di eliminazione cantina (blocca eliminazione della principale)
drop policy if exists "cellars: solo owner elimina la cantina condivisa" on public.cellars;
create policy "cellars: solo owner elimina la cantina condivisa"
  on public.cellars for delete
  using (auth.uid() = owner_id and is_default = false);

-- Aggiorna il trigger di registrazione per creare la cantina principale
-- anche ai nuovi utenti che si registreranno da qui in avanti
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_cellar_id uuid;
begin
  insert into public.profiles (id, full_name, assoc, card, delegazione, delegazione_custom)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'assoc', ''),
    coalesce(new.raw_user_meta_data->>'card', ''),
    '', ''
  )
  on conflict (id) do nothing;

  insert into public.cellars (name, owner_id, invite_code, is_default)
  values ('La mia cantina', new.id, upper(substr(md5(random()::text), 1, 6)), true)
  returning id into new_cellar_id;

  insert into public.cellar_members (cellar_id, user_id, status)
  values (new_cellar_id, new.id, 'accepted');

  return new;
end;
$$;

-- ════════════════════════════════════════════════════════════════
-- CONDIVISIONE CANTINA (v2 — semplificata)
-- Un utente può condividere la PROPRIA cantina personale con altri.
-- Niente cantine multiple: chi accetta l'invito vede e modifica gli
-- stessi vini del proprietario, come se fosse la propria — tutti
-- alla pari. Nessuna tabella "cellars" separata, nessun cellar_id
-- sui vini: i vini restano legati a un solo user_id (il proprietario
-- originale), e la condivisione è solo un permesso di accesso in più.
-- ════════════════════════════════════════════════════════════════

create table if not exists public.cellar_shares (
  owner_id    uuid not null references auth.users(id) on delete cascade,
  member_id   uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'pending',  -- 'pending' | 'accepted'
  invited_by  uuid references auth.users(id),
  created_at  timestamptz default now(),
  primary key (owner_id, member_id),
  constraint no_self_share check (owner_id <> member_id)
);
alter table public.cellar_shares enable row level security;

-- Funzione di supporto: ho accesso alla cantina di p_owner_id?
-- (sono io stesso, oppure il proprietario mi ha condiviso la sua
-- cantina e ho accettato)
create or replace function public.has_cellar_access(p_owner_id uuid, p_viewer_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select p_owner_id = p_viewer_id
  or exists (
    select 1 from public.cellar_shares cs
    where cs.owner_id = p_owner_id and cs.member_id = p_viewer_id and cs.status = 'accepted'
  );
$$;

-- ── Policy: cellar_shares ──
-- Nota: queste policy non interrogano mai cellar_shares al loro
-- interno, quindi non c'è rischio di ricorsione (lezione imparata
-- dalla versione precedente con le cantine multiple).
create policy "cellar_shares: vedo le condivisioni che mi riguardano"
  on public.cellar_shares for select
  using (auth.uid() = owner_id or auth.uid() = member_id);

create policy "cellar_shares: solo il proprietario invita qualcuno alla sua cantina"
  on public.cellar_shares for insert
  with check (auth.uid() = owner_id);

create policy "cellar_shares: il destinatario accetta il proprio invito"
  on public.cellar_shares for update
  using (auth.uid() = member_id);

create policy "cellar_shares: il membro esce da solo, o il proprietario rimuove l'accesso"
  on public.cellar_shares for delete
  using (auth.uid() = member_id or auth.uid() = owner_id);

-- ── Policy: wines — estende l'accesso a chi ha una condivisione accettata ──
-- Si aggiungono alle policy "own" già esistenti (permissive, si
-- combinano con OR) — non le sostituiscono.
create policy "wines: accesso in lettura se il proprietario condivide con me"
  on public.wines for select
  using (public.has_cellar_access(wines.user_id, auth.uid()));

create policy "wines: accesso in inserimento se il proprietario condivide con me"
  on public.wines for insert
  with check (public.has_cellar_access(wines.user_id, auth.uid()));

create policy "wines: accesso in modifica se il proprietario condivide con me"
  on public.wines for update
  using (public.has_cellar_access(wines.user_id, auth.uid()));

create policy "wines: accesso in eliminazione se il proprietario condivide con me"
  on public.wines for delete
  using (public.has_cellar_access(wines.user_id, auth.uid()));

-- ════════════════════════════════════════════
-- ABBONAMENTO PREMIUM (Stripe) — scansione AI
-- ════════════════════════════════════════════
alter table public.profiles add column if not exists stripe_customer_id text;
alter table public.profiles add column if not exists stripe_subscription_id text;
alter table public.profiles add column if not exists subscription_status text; -- 'active' | 'canceled' | 'past_due' | null

-- ai_scan_enabled riflette lo stato dell'abbonamento: viene attivato/
-- disattivato automaticamente dal webhook Stripe (vedi Edge Function
-- stripe-webhook), non più solo a mano dall'amministratore.

-- ════════════════════════════════════════════
-- CONFERMA EMAIL CUSTOM (via Resend)
-- ════════════════════════════════════════════
create table if not exists public.email_confirmations (
  token uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  sent_at timestamptz not null default now(),
  confirmed_at timestamptz
);
alter table public.email_confirmations enable row level security;

create index if not exists email_confirmations_user_id_idx
  on public.email_confirmations (user_id);

alter table public.profiles add column if not exists email_confirmed boolean not null default false;

create or replace function public.get_user_id_by_email(lookup_email text)
returns uuid
language sql
security definer
set search_path = public
as $$
  select id from auth.users where email = lookup_email limit 1;
$$;

revoke all on function public.get_user_id_by_email(text) from public, anon, authenticated;

-- ════════════════════════════════════════════════════════════════
-- FIX: nome utente non in chiaro nelle richieste di follow e negli
-- inviti a condividere la cantina. Chi manda una richiesta/invito
-- non ha necessariamente il profilo pubblico (is_public default
-- false), quindi la policy "profili pubblici visibili a tutti" non
-- basta: il destinatario non riusciva a leggere profiles.full_name
-- di chi gli aveva scritto e vedeva il fallback generico ("Utente").
-- Queste due policy si aggiungono (OR) a quelle esistenti su
-- profiles e rendono leggibile il profilo di chi ha con te una
-- relazione di follow o di condivisione cantina, pending o accettata.
-- ════════════════════════════════════════════════════════════════

drop policy if exists "profiles: visibili a chi ha una richiesta di follow con me" on public.profiles;
create policy "profiles: visibili a chi ha una richiesta di follow con me"
  on public.profiles for select
  using (
    exists (
      select 1 from public.follows f
      where (f.follower_id = auth.uid() and f.followee_id = profiles.id)
         or (f.followee_id = auth.uid() and f.follower_id = profiles.id)
    )
  );

drop policy if exists "profiles: visibili a chi condivide una cantina con me" on public.profiles;
create policy "profiles: visibili a chi condivide una cantina con me"
  on public.profiles for select
  using (
    exists (
      select 1 from public.cellar_shares cs
      where (cs.owner_id = auth.uid() and cs.member_id = profiles.id)
         or (cs.member_id = auth.uid() and cs.owner_id = profiles.id)
    )
  );
grant execute on function public.get_user_id_by_email(text) to service_role;

-- ════════════════════════════════════════════
-- AIS — scheda analitico-descrittiva (in aggiunta a quella a punteggio,
-- che l'AIS compila sempre entrambe: niente toggle, i due schemi
-- convivono nello stesso record sotto deg_schema = 'ais')
-- ════════════════════════════════════════════
alter table public.wines add column if not exists ais_desc_params jsonb;

-- ════════════════════════════════════════════
-- Pop-up "profilo pubblico" al primo accesso — l'impostazione is_public
-- (da cui dipende tutto il Network) è sepolta nella schermata Profilo e
-- resta disattiva di default: questo flag traccia se all'utente è già
-- stato mostrato il pop-up di spiegazione/attivazione, per non
-- richiederlo ad ogni sessione.
-- ════════════════════════════════════════════
alter table public.profiles add column if not exists public_prompt_seen boolean not null default false;

-- ════════════════════════════════════════════════════════════════
-- Posizione in cantina — tre livelli configurabili dal proprietario
-- della cantina nel proprio profilo (es. livello 1 = luogo fisico
-- "Cantina casa"/"Stock", livello 2 = zona "Bianchi"/"Rossi", livello
-- 3 = piano/ripiano "Piano 1"/"Piano 2"/"Piano 3"), poi assegnabili a
-- ciascun vino. Un vino può avere più posizioni (es. alcune bottiglie
-- in cantina, altre nello stock), quindi cellar_positions è un array
-- di combinazioni {l1,l2,l3}. Salviamo uno snapshot testuale delle
-- etichette scelte (non un riferimento a un id) così una posizione
-- resta leggibile sul vino anche se poi viene rinominata o rimossa
-- dalle liste in profiles.
-- ════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists cellar_pos_l1 text[] not null default '{}';
alter table public.profiles add column if not exists cellar_pos_l2 text[] not null default '{}';
alter table public.profiles add column if not exists cellar_pos_l3 text[] not null default '{}';

alter table public.wines add column if not exists cellar_positions jsonb not null default '[]';

-- ════════════════════════════════════════════════════════════════
-- Posizione in cantina — da tre liste piatte a un albero gerarchico:
-- il livello 2 (zona) appartiene a uno specifico livello 1 (posizione),
-- il livello 3 (piano) appartiene a uno specifico livello 2, invece di
-- essere tre elenchi indipendenti mostrati sempre tutti insieme.
-- cellar_pos_l1/l2/l3 restano in tabella (non usate più dal frontend)
-- solo per non perdere lo storico; cellar_positions_tree è la nuova
-- fonte di verità:
--   [{ "name": "Cantina casa", "children": [
--        { "name": "Rossi", "children": [ {"name":"Piano 1","children":[]}, ... ] },
--        ...
--   ]}, ...]
-- wines.cellar_positions non cambia: resta uno snapshot testuale
-- {l1,l2,l3} per ogni posizione assegnata al vino.
-- ════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists cellar_positions_tree jsonb not null default '[]';

-- Migrazione una tantum: chi aveva già inserito valori nel vecchio
-- livello 1 piatto (cellar_pos_l1) li ritrova come nodi radice
-- dell'albero, pronti per aggiungerci sotto zone e piani.
update public.profiles
set cellar_positions_tree = (
  select coalesce(jsonb_agg(jsonb_build_object('name', v, 'children', '[]'::jsonb)), '[]'::jsonb)
  from unnest(cellar_pos_l1) as v
)
where (cellar_positions_tree = '[]'::jsonb or cellar_positions_tree is null)
  and cellar_pos_l1 is not null and array_length(cellar_pos_l1, 1) > 0;

-- ════════════════════════════════════════════════════════════════
-- Un membro di cantina condivisa deve poter leggere l'albero posizioni
-- del proprietario, per popolare le select quando assegna una posizione
-- a un vino che non è suo. Finora questo passava dalla policy generale
-- "profiles: visibili a chi condivide una cantina con me" via un
-- semplice select dal client — ma un membro (es. Samantha) risultava
-- non vedere affatto le opzioni, segno che quella lettura falliva
-- silenziosamente lato client (nessun errore: RLS filtra le righe,
-- non solleva eccezioni). Invece di continuare a fidarsi di una policy
-- generale su cui il client non ha visibilità diretta in caso di
-- fallimento, questa funzione fa il controllo di accesso esplicitamente
-- e restituisce l'albero solo se autorizzato — stesso principio già
-- usato per get_user_id_by_email.
-- ════════════════════════════════════════════════════════════════
create or replace function public.get_cellar_position_tree(p_owner_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select p.cellar_positions_tree
  from public.profiles p
  where p.id = p_owner_id
    and (
      p_owner_id = auth.uid()
      or exists (
        select 1 from public.cellar_shares cs
        where cs.owner_id = p_owner_id
          and cs.member_id = auth.uid()
          and cs.status = 'accepted'
      )
    );
$$;

revoke all on function public.get_cellar_position_tree(uuid) from public, anon;
grant execute on function public.get_cellar_position_tree(uuid) to authenticated;

-- ════════════════════════════════════════════════════════════════
-- Anagrafica cantine (produttori): registro condiviso agganciato ai
-- vini via wines.winery_id, per dare in futuro una scheda "scopri di
-- più" (zona, sito, storia, logo) e permettere un primo import da
-- fonte esterna (es. elenchi delle associazioni di turismo del vino).
--
-- Le schede si creano da sole (solo il nome, name_normalized calcolato
-- lato client con lo stesso criterio case/spazi-insensitive già usato
-- per i doppioni vino) quando un utente salva un vino con un
-- produttore che non trova corrispondenza — vedi findOrCreateWinery()
-- in index.html. I dettagli extra li può scrivere solo l'admin
-- (profiles.is_admin), per evitare vandalismo su un registro condiviso
-- da tutti gli utenti.
-- ════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists is_admin boolean not null default false;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

create table if not exists public.wineries (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_normalized text not null,
  region text,
  website text,
  description text,
  logo_url text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists wineries_name_normalized_key on public.wineries (name_normalized);

alter table public.wines add column if not exists winery_id uuid references public.wineries(id);

alter table public.wineries enable row level security;

drop policy if exists "wineries: lettura per chiunque autenticato" on public.wineries;
create policy "wineries: lettura per chiunque autenticato"
  on public.wineries for select to authenticated using (true);

-- Chiunque autenticato può creare una scheda "stub" (solo nome, nessun
-- dettaglio) — è quello che succede in automatico salvando un vino.
-- Solo l'admin può inserire (o modificare) una scheda già arricchita.
drop policy if exists "wineries: stub per tutti, completa solo admin" on public.wineries;
create policy "wineries: stub per tutti, completa solo admin"
  on public.wineries for insert to authenticated
  with check (
    public.is_admin()
    or (region is null and website is null and description is null and logo_url is null)
  );

drop policy if exists "wineries: modifica solo admin" on public.wineries;
create policy "wineries: modifica solo admin"
  on public.wineries for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "wineries: eliminazione solo admin" on public.wineries;
create policy "wineries: eliminazione solo admin"
  on public.wineries for delete to authenticated
  using (public.is_admin());

-- Loghi cantina nello stesso bucket "wine-labels" (già pubblico in
-- lettura), sotto il prefisso wineries/ — scrittura riservata all'admin.
drop policy if exists "wine-labels: admin scrive i loghi cantina" on storage.objects;
create policy "wine-labels: admin scrive i loghi cantina"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'wineries' and public.is_admin());

drop policy if exists "wine-labels: admin aggiorna i loghi cantina" on storage.objects;
create policy "wine-labels: admin aggiorna i loghi cantina"
  on storage.objects for update to authenticated
  using (bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'wineries' and public.is_admin())
  with check (bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'wineries' and public.is_admin());

-- Da lanciare una volta sola, sostituendo la tua email: ti rende admin
-- e sblocca la sezione "Amministrazione" nel profilo.
-- update public.profiles set is_admin = true
-- where id = (select id from auth.users where email = 'TUA-EMAIL@esempio.it');

-- ════════════════════════════════════════════════════════════════
-- Provincia della cantina, per riusare in compilazione la stessa
-- struttura Regione → Provincia già usata nel form vino (GEO_REGIONS /
-- GEO_PROVINCES_ITALIA in index.html), invece di un unico campo libero
-- "Zona / regione". In visualizzazione i due campi vengono concatenati
-- ("Regione, Provincia").
-- ════════════════════════════════════════════════════════════════
alter table public.wineries add column if not exists province text;

-- ════════════════════════════════════════════════════════════════
-- Paese della cantina, per completare la cascata Paese → Regione →
-- Provincia identica a quella del form vino (GEO_REGIONS dipende dal
-- paese, GEO_PROVINCES_ITALIA/il campo provincia si applicano solo
-- quando il paese è Italia).
-- ════════════════════════════════════════════════════════════════
alter table public.wineries add column if not exists country text;

drop policy if exists "wineries: stub per tutti, completa solo admin" on public.wineries;
create policy "wineries: stub per tutti, completa solo admin"
  on public.wineries for insert to authenticated
  with check (
    public.is_admin()
    or (country is null and region is null and province is null and website is null and description is null and logo_url is null)
  );

-- ════════════════════════════════════════════════════════════════
-- Catalogo dei vini prodotti da una cantina (curato dall'admin), distinto
-- dai vini che gli utenti hanno effettivamente in cantina (wines.winery_id):
-- una cosa è "questa cantina produce l'Amarone", un'altra è "Mario ha
-- l'Amarone di questa cantina nella sua cantina personale".
-- ════════════════════════════════════════════════════════════════
create table if not exists public.winery_wines (
  id uuid primary key default gen_random_uuid(),
  winery_id uuid not null references public.wineries(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);
create index if not exists winery_wines_winery_id_idx on public.winery_wines(winery_id);

alter table public.winery_wines enable row level security;

drop policy if exists "winery_wines: lettura per chiunque autenticato" on public.winery_wines;
create policy "winery_wines: lettura per chiunque autenticato"
  on public.winery_wines for select to authenticated using (true);

drop policy if exists "winery_wines: scrittura solo admin" on public.winery_wines;
create policy "winery_wines: scrittura solo admin"
  on public.winery_wines for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Uvaggio e link (es. alla scheda del vino sul sito della cantina) per
-- ogni voce del catalogo.
alter table public.winery_wines add column if not exists grapes text;
alter table public.winery_wines add column if not exists link text;

-- ════════════════════════════════════════════════════════════════
-- Vini "orfani": inseriti prima che esistesse l'anagrafica cantine (o
-- comunque rimasti senza winery_id) — il produttore in wines.producer
-- non è agganciato a nessuna scheda. Servono due funzioni SECURITY
-- DEFINER perché wines ha RLS per-utente (solo i propri vini + cantine
-- condivise): l'admin deve poter vedere/collegare TUTTI i vini
-- dell'app, non solo i suoi. Stesso principio già usato per
-- get_cellar_position_tree — controllo di accesso esplicito dentro la
-- funzione, invece di allargare le policy RLS generali.
-- ════════════════════════════════════════════════════════════════
create or replace function public.get_unlinked_producers()
returns table(producer text, wine_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select w.producer, count(*)::bigint as wine_count
  from public.wines w
  where w.winery_id is null
    and w.producer is not null
    and trim(w.producer) <> ''
    and public.is_admin()
  group by w.producer
  order by count(*) desc, w.producer;
$$;
revoke all on function public.get_unlinked_producers() from public, anon;
grant execute on function public.get_unlinked_producers() to authenticated;

create or replace function public.link_producer_to_winery(p_producer text, p_winery_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  update public.wines
  set winery_id = p_winery_id
  where producer = p_producer
    and winery_id is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.link_producer_to_winery(text, uuid) from public, anon;
grant execute on function public.link_producer_to_winery(text, uuid) to authenticated;

-- ════════════════════════════════════════════════════════════════
-- Eventi (fiere, degustazioni...): stessa impostazione dell'anagrafica
-- cantine — registro condiviso, lettura per chiunque autenticato,
-- scrittura solo admin. Prima versione "struttura": solo inserimento
-- manuale, il reperimento automatico dal web è rimandato a dopo.
-- main_features è testo libero, una riga per caratteristica (mostrata
-- come elenco puntato in lettura) — non una tabella a parte, per non
-- appesantire una prima versione pensata per essere semplice.
-- ════════════════════════════════════════════════════════════════
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  region text,
  province text,
  website text,
  description text,
  main_features text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.events enable row level security;

drop policy if exists "events: lettura per chiunque autenticato" on public.events;
create policy "events: lettura per chiunque autenticato"
  on public.events for select to authenticated using (true);

drop policy if exists "events: scrittura solo admin" on public.events;
create policy "events: scrittura solo admin"
  on public.events for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ════════════════════════════════════════════════════════════════
-- Data, categoria e associazioni collegate, aggiunte con alter table
-- (non nel create table sopra) perché la tabella potrebbe già esistere
-- da un lancio precedente di questo stesso script — "create table if
-- not exists" in quel caso non farebbe nulla e le nuove colonne non
-- comparirebbero mai. category è testo libero lato DB (come
-- wines.type): l'elenco chiuso di opzioni è solo nella <select> del
-- form. associations è un array perché un evento può coinvolgere più
-- associazioni insieme (es. FISAR e Slow Food).
-- ════════════════════════════════════════════════════════════════
alter table public.events add column if not exists category text;
alter table public.events add column if not exists date_from date;
alter table public.events add column if not exists date_to date;
alter table public.events add column if not exists associations text[] not null default '{}';
create index if not exists events_date_from_idx on public.events(date_from);

-- Indirizzo e nome della location (es. "Villa Reale", distinto dalla via)
-- dell'evento, oltre a regione e provincia.
alter table public.events add column if not exists address text;
alter table public.events add column if not exists location_name text;

-- ════════════════════════════════════════════════════════════════
-- Tabella generica per le opzioni a scelta chiusa usate nei form
-- (categorie eventi, associazioni collegate, e altre liste future) —
-- invece di elenchi fissi nel codice, modificabili dall'admin dalla
-- schermata "Configurazione liste" senza bisogno di un deploy. Una
-- riga per (list_key, valore); sort_order determina l'ordine di
-- comparsa nei form (nuovi valori aggiunti in coda).
-- ════════════════════════════════════════════════════════════════
create table if not exists public.config_lists (
  id uuid primary key default gen_random_uuid(),
  list_key text not null,
  value text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists config_lists_key_value_key on public.config_lists (list_key, value);
create index if not exists config_lists_key_idx on public.config_lists (list_key);

alter table public.config_lists enable row level security;

drop policy if exists "config_lists: lettura per chiunque autenticato" on public.config_lists;
create policy "config_lists: lettura per chiunque autenticato"
  on public.config_lists for select to authenticated using (true);

drop policy if exists "config_lists: scrittura solo admin" on public.config_lists;
create policy "config_lists: scrittura solo admin"
  on public.config_lists for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Popola le due liste con gli stessi valori finora fissi nel codice, così
-- il passaggio alla tabella non cambia nulla per chi già usa l'app.
insert into public.config_lists (list_key, value, sort_order) values
  ('event_category', 'Vino', 0),
  ('event_category', 'Food', 1),
  ('event_category', 'Enogastronomia', 2),
  ('event_category', 'Sagra Paesana', 3),
  ('event_association', 'FISAR', 0),
  ('event_association', 'AIS', 1),
  ('event_association', 'ONAV', 2),
  ('event_association', 'Slow Food', 3),
  ('event_association', 'Slow Wine', 4),
  ('event_association', 'ONAF', 5)
on conflict (list_key, value) do nothing;

-- ════════════════════════════════════════════════════════════════
-- Recapiti dell'evento (telefono/email), per chi preferisce essere
-- contattato invece di visitare il sito. Aggiunti con alter table
-- per lo stesso motivo di date_from/category sopra: la tabella
-- events esiste già dai lanci precedenti di questo script.
-- ════════════════════════════════════════════════════════════════
alter table public.events add column if not exists phone text;
alter table public.events add column if not exists email text;

-- ════════════════════════════════════════════════════════════════
-- Eventi preferiti: un utente può segnare un evento come preferito
-- per ritrovarlo subito nella sezione "I tuoi prossimi eventi" in
-- cima alla schermata Eventi. Una riga per (utente, evento); niente
-- colonne oltre alla chiave — nessun dato da aggiornare, solo
-- presenza/assenza della riga.
-- ════════════════════════════════════════════════════════════════
create table if not exists public.event_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);

alter table public.event_favorites enable row level security;

drop policy if exists "event_favorites: solo le proprie righe" on public.event_favorites;
create policy "event_favorites: solo le proprie righe"
  on public.event_favorites for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ════════════════════════════════════════════════════════════════
-- Chi si registra con Google non passa dal form di registrazione, quindi
-- non ha mai indicato associazione/tessera: assoc_prompt_pending segna i
-- profili nati così, per mostrare loro una sola volta (al primo accesso)
-- un pop-up che chiede questi dati — esattamente come già succede per il
-- pop-up "profilo pubblico" (public_prompt_seen), stesso meccanismo.
-- Chi si registra con email/password li ha già forniti nel form, quindi
-- resta false per loro (valore di default).
-- ════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists assoc_prompt_pending boolean not null default false;

-- Ridefinizione di handle_new_user() (vedi sopra) che imposta
-- assoc_prompt_pending a true solo per i nuovi account creati via Google.
-- "create or replace" sovrascrive la versione precedente della funzione:
-- rilanciando l'intero script, questa in fondo al file è quella che vince.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_cellar_id uuid;
begin
  insert into public.profiles (id, full_name, assoc, card, delegazione, delegazione_custom, assoc_prompt_pending)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'assoc', ''),
    coalesce(new.raw_user_meta_data->>'card', ''),
    '', '',
    (new.raw_app_meta_data->>'provider') = 'google'
  )
  on conflict (id) do nothing;

  insert into public.cellars (name, owner_id, invite_code, is_default)
  values ('La mia cantina', new.id, upper(substr(md5(random()::text), 1, 6)), true)
  returning id into new_cellar_id;

  insert into public.cellar_members (cellar_id, user_id, status)
  values (new_cellar_id, new.id, 'accepted');

  return new;
end;
$$;

-- ════════════════════════════════════════════════════════════════
-- CANTINE CHE SI AUTOGESTISCONO — una cantina può richiedere di
-- collegarsi alla propria scheda in anagrafica (o proporne una nuova se
-- non esiste ancora) e, una volta approvata da un admin, gestire da sola
-- i propri dati, il proprio catalogo vini e i propri eventi (questi
-- ultimi pubblicati solo dopo approvazione admin — vedi più sotto).
-- ════════════════════════════════════════════════════════════════

-- owner_user_id: chi gestisce questa scheda oltre all'admin. Nullo finché
-- nessuna richiesta di collegamento è stata approvata.
alter table public.wineries add column if not exists owner_user_id uuid references auth.users(id) on delete set null;

-- La modifica (non l'eliminazione, che resta solo admin) è ora permessa
-- anche al proprietario collegato, non solo all'admin.
drop policy if exists "wineries: modifica solo admin" on public.wineries;
create policy "wineries: modifica admin o proprietario collegato"
  on public.wineries for update to authenticated
  using (public.is_admin() or owner_user_id = auth.uid())
  with check (public.is_admin() or owner_user_id = auth.uid());

-- Stesso discorso per il catalogo vini prodotti: lo gestisce anche il
-- proprietario della cantina a cui appartiene, non solo l'admin.
drop policy if exists "winery_wines: scrittura solo admin" on public.winery_wines;
create policy "winery_wines: scrittura admin o proprietario cantina"
  on public.winery_wines for all to authenticated
  using (
    public.is_admin()
    or winery_id in (select id from public.wineries where owner_user_id = auth.uid())
  )
  with check (
    public.is_admin()
    or winery_id in (select id from public.wineries where owner_user_id = auth.uid())
  );

-- Il logo si carica nello storage con le stesse regole: admin o
-- proprietario della cantina a cui appartiene il file (path
-- wineries/<winery_id>-....jpg, il primo pezzo dopo il prefisso).
drop policy if exists "wine-labels: admin scrive i loghi cantina" on storage.objects;
create policy "wine-labels: admin o proprietario scrive i loghi cantina"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'wineries'
    and (
      public.is_admin()
      or (substring(name from '^wineries/([0-9a-fA-F-]{36})-'))::uuid in (select id from public.wineries where owner_user_id = auth.uid())
    )
  );

drop policy if exists "wine-labels: admin aggiorna i loghi cantina" on storage.objects;
create policy "wine-labels: admin o proprietario aggiorna i loghi cantina"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'wineries'
    and (
      public.is_admin()
      or (substring(name from '^wineries/([0-9a-fA-F-]{36})-'))::uuid in (select id from public.wineries where owner_user_id = auth.uid())
    )
  )
  with check (
    bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'wineries'
    and (
      public.is_admin()
      or (substring(name from '^wineries/([0-9a-fA-F-]{36})-'))::uuid in (select id from public.wineries where owner_user_id = auth.uid())
    )
  );

-- Richieste di collegamento cantina-utente. winery_id valorizzato se
-- l'utente ha scelto una cantina già in anagrafica; null + proposed_name
-- se ne propone una nuova (che l'admin crea contestualmente
-- all'approvazione). Una per utente per volta: non se ne può aprire una
-- seconda finché la prima è ancora "pending".
create table if not exists public.winery_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  winery_id uuid references public.wineries(id) on delete cascade,
  proposed_name text,
  status text not null default 'pending' check (status in ('pending','accepted','rejected')),
  note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id)
);
create unique index if not exists winery_claims_one_pending_per_user
  on public.winery_claims (user_id) where (status = 'pending');

alter table public.winery_claims enable row level security;

drop policy if exists "winery_claims: lettura proprie richieste o admin" on public.winery_claims;
create policy "winery_claims: lettura proprie richieste o admin"
  on public.winery_claims for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "winery_claims: crea la propria richiesta" on public.winery_claims;
create policy "winery_claims: crea la propria richiesta"
  on public.winery_claims for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists "winery_claims: solo admin approva o rifiuta" on public.winery_claims;
create policy "winery_claims: solo admin approva o rifiuta"
  on public.winery_claims for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "winery_claims: elimina la propria richiesta in attesa o admin" on public.winery_claims;
create policy "winery_claims: elimina la propria richiesta in attesa o admin"
  on public.winery_claims for delete to authenticated
  using (public.is_admin() or (user_id = auth.uid() and status = 'pending'));

-- ════════════════════════════════════════════════════════════════
-- EVENTI — una cantina collegata (owner_user_id) può inserire i propri
-- eventi, ma restano "in attesa" (status pending, invisibili a tutti
-- tranne admin e alla cantina stessa) finché un admin non li approva.
-- Gli eventi già esistenti e quelli creati da un admin restano invece
-- 'approved' di default, come già si comportavano prima di questa
-- colonna — nessun cambiamento visibile per loro.
-- ════════════════════════════════════════════════════════════════
alter table public.events add column if not exists status text not null default 'approved' check (status in ('pending','approved','rejected'));
alter table public.events add column if not exists winery_id uuid references public.wineries(id) on delete set null;
create index if not exists events_winery_id_idx on public.events(winery_id);

drop policy if exists "events: lettura per chiunque autenticato" on public.events;
create policy "events: lettura"
  on public.events for select to authenticated
  using (
    status = 'approved'
    or public.is_admin()
    or (winery_id is not null and winery_id in (select id from public.wineries where owner_user_id = auth.uid()))
  );

drop policy if exists "events: scrittura solo admin" on public.events;
drop policy if exists "events: inserimento" on public.events;
create policy "events: inserimento"
  on public.events for insert to authenticated
  with check (
    public.is_admin()
    or (status = 'pending' and winery_id in (select id from public.wineries where owner_user_id = auth.uid()))
  );

drop policy if exists "events: modifica" on public.events;
create policy "events: modifica"
  on public.events for update to authenticated
  using (
    public.is_admin()
    or (winery_id is not null and winery_id in (select id from public.wineries where owner_user_id = auth.uid()))
  )
  with check (
    public.is_admin()
    or (status = 'pending' and winery_id in (select id from public.wineries where owner_user_id = auth.uid()))
  );

drop policy if exists "events: eliminazione" on public.events;
create policy "events: eliminazione"
  on public.events for delete to authenticated
  using (
    public.is_admin()
    or (winery_id is not null and winery_id in (select id from public.wineries where owner_user_id = auth.uid()))
  );

-- Chiude una falla: senza questo, chiunque potrebbe auto-assegnarsi la
-- proprietà di una cantina nuova con un insert diretto (lasciando gli
-- altri campi vuoti per restare nel caso "stub" consentito a tutti),
-- scavalcando del tutto la richiesta di collegamento sopra.
drop policy if exists "wineries: stub per tutti, completa solo admin" on public.wineries;
create policy "wineries: stub per tutti, completa solo admin"
  on public.wineries for insert to authenticated
  with check (
    public.is_admin()
    or (country is null and region is null and province is null and website is null and description is null and logo_url is null and owner_user_id is null)
  );

-- Le richieste di collegamento cantina vanno mostrate all'admin col nome
-- di chi le ha fatte: profiles/auth.users non sono leggibili in RLS per
-- un utente arbitrario (solo per sé stessi o in contesti specifici, es.
-- cantina condivisa), quindi serve una funzione SECURITY DEFINER come già
-- fatto per get_unlinked_producers().
create or replace function public.get_pending_winery_claims()
returns table (
  id uuid, user_id uuid, winery_id uuid, proposed_name text,
  note text, created_at timestamptz,
  requester_name text, requester_email text, existing_winery_name text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  return query
    select c.id, c.user_id, c.winery_id, c.proposed_name, c.note, c.created_at,
           p.full_name, u.email, w.name
    from public.winery_claims c
    left join public.profiles p on p.id = c.user_id
    left join auth.users u on u.id = c.user_id
    left join public.wineries w on w.id = c.winery_id
    where c.status = 'pending'
    order by c.created_at;
end;
$$;
grant execute on function public.get_pending_winery_claims() to authenticated;

-- ════════════════════════════════════════════════════════════════
-- Tutorial (panoramica guidata a step): una tantum al primo accesso,
-- sempre richiamabile da Profilo → Tutorial. Il default è false così i
-- nuovi account lo vedono al primo accesso; per chi è già registrato da
-- prima di questa colonna va invece marcato "già visto" con l'update qui
-- sotto — da lanciare UNA SOLA VOLTA subito dopo la alter table, non ad
-- ogni ri-esecuzione dello script (altrimenti azzererebbe tutorial_seen
-- anche per chi nel frattempo l'ha già visto).
-- ════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists tutorial_seen boolean not null default false;

-- Da lanciare una volta sola, subito dopo la riga sopra:
-- update public.profiles set tutorial_seen = true;

-- ════════════════════════════════════════════════════════════════
-- FIX: le registrazioni fallivano con "Database error saving new user"
-- perché handle_new_user() scrive ancora su public.cellars/cellar_members
-- (il vecchio modello v1 di multi-cantina, superato da cellar_shares —
-- vedi CLAUDE.md), tabelle che su questo database non sono mai state
-- create. Il frontend non le legge mai (nessun riferimento in index.html
-- o nelle Edge Function): non serve crearle, la dipendenza si può
-- rimuovere del tutto dal trigger, così la registrazione non dipende più
-- da tabelle ormai morte.
-- ════════════════════════════════════════════════════════════════
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, assoc, card, delegazione, delegazione_custom, assoc_prompt_pending)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'assoc', ''),
    coalesce(new.raw_user_meta_data->>'card', ''),
    '', '',
    (new.raw_app_meta_data->>'provider') = 'google'
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ════════════════════════════════════════════════════════════════
-- PRIVACY POLICY — spunta obbligatoria in registrazione (email/password
-- e Google), con timestamp di quando è stata accettata. Nullo per gli
-- account già esistenti prima di questa colonna (non richiesta
-- retroattivamente) e per un eventuale account creato senza passare da
-- qui (caso limite non previsto dal flusso attuale).
-- ════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists privacy_accepted_at timestamptz;

-- Ridefinizione di handle_new_user() che imposta privacy_accepted_at a
-- ora se il form di registrazione (email/password) ha passato
-- privacy_accepted:true nei metadati di signUp() — vedi doRegister() in
-- index.html. Per la registrazione via Google, che non passa metadati
-- personalizzati, il client imposta privacy_accepted_at con un update
-- separato subito dopo il redirect (vedi doGoogleAuth()/loadProfile()).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, assoc, card, delegazione, delegazione_custom, assoc_prompt_pending, privacy_accepted_at)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'assoc', ''),
    coalesce(new.raw_user_meta_data->>'card', ''),
    '', '',
    (new.raw_app_meta_data->>'provider') = 'google',
    case when (new.raw_user_meta_data->>'privacy_accepted')::boolean then now() else null end
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ════════════════════════════════════════════════════════════════
-- APPROFONDISCI — sezione "Approfondimenti" (home-card/nav-menu finora
-- placeholder "In arrivo"): un blog editoriale (solo admin scrive, tutti
-- leggono i post pubblicati) più due archivi di consultazione, Vitigni e
-- Denominazioni, popolati inizialmente da un import di massa (vedi sotto)
-- e poi correggibili/estendibili uno alla volta dall'admin come ogni
-- altra anagrafica curata (stesso schema "lettura per chiunque
-- autenticato, scrittura solo admin" già usato da wineries/events).
-- ════════════════════════════════════════════════════════════════

create table if not exists public.grape_varieties (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  rnv_number integer unique,
  berry_color text,
  aromatic text,
  regions text[] not null default '{}',
  synonyms text[] not null default '{}',
  registration_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists grape_varieties_name_idx on public.grape_varieties (name);

alter table public.grape_varieties enable row level security;

drop policy if exists "grape_varieties: lettura per chiunque autenticato" on public.grape_varieties;
create policy "grape_varieties: lettura per chiunque autenticato"
  on public.grape_varieties for select to authenticated using (true);

drop policy if exists "grape_varieties: scrittura solo admin" on public.grape_varieties;
create policy "grape_varieties: scrittura solo admin"
  on public.grape_varieties for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create table if not exists public.wine_denominations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  colors text[] not null default '{}',
  type text,
  region text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists wine_denominations_name_idx on public.wine_denominations (name);

alter table public.wine_denominations enable row level security;

drop policy if exists "wine_denominations: lettura per chiunque autenticato" on public.wine_denominations;
create policy "wine_denominations: lettura per chiunque autenticato"
  on public.wine_denominations for select to authenticated using (true);

drop policy if exists "wine_denominations: scrittura solo admin" on public.wine_denominations;
create policy "wine_denominations: scrittura solo admin"
  on public.wine_denominations for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- A differenza degli archivi, il blog ha una bozza non ancora pronta per
-- il pubblico: la lettura resta aperta a tutti solo per i post
-- pubblicati, l'admin invece vede/gestisce anche le bozze.
create table if not exists public.blog_posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  cover_image_url text,
  status text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists blog_posts_status_idx on public.blog_posts (status, published_at desc);

alter table public.blog_posts enable row level security;

drop policy if exists "blog_posts: lettura pubblicati o admin" on public.blog_posts;
create policy "blog_posts: lettura pubblicati o admin"
  on public.blog_posts for select to authenticated
  using (status = 'published' or public.is_admin());

drop policy if exists "blog_posts: scrittura solo admin" on public.blog_posts;
create policy "blog_posts: scrittura solo admin"
  on public.blog_posts for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Copertine articoli nello stesso bucket "wine-labels" già usato per i
-- loghi cantina, sotto il prefisso blog/ — stessa policy admin-only, solo
-- il prefisso cambia.
drop policy if exists "wine-labels: admin scrive le copertine blog" on storage.objects;
create policy "wine-labels: admin scrive le copertine blog"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'blog' and public.is_admin());

drop policy if exists "wine-labels: admin aggiorna le copertine blog" on storage.objects;
create policy "wine-labels: admin aggiorna le copertine blog"
  on storage.objects for update to authenticated
  using (bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'blog' and public.is_admin())
  with check (bucket_id = 'wine-labels' and (storage.foldername(name))[1] = 'blog' and public.is_admin());

-- ════════════════════════════════════════════════════════════════
-- Import iniziale dell'archivio Vitigni: 640 varietà, estratte dal Registro
-- Nazionale delle Varietà di Vite (export ufficiale CRA-VIT/MASAF,
-- sezione "Varietà da Vino", 23/09/2026) — una riga per varietà (escluse
-- le sotto-registrazioni di clone), colore bacca dedotto dal suffisso
-- ufficiale del nome (N.=nera, B.=bianca, Rs.=rosa, G.=grigia; assente
-- per ~30 varietà internazionali prive di suffisso, lasciato null,
-- correggibile a mano). "Regioni" non è presente in questa fonte
-- ufficiale (è un arricchimento editoriale di terzi, non un dato di
-- registro): resta vuoto, da compilare eventualmente in un secondo
-- momento voce per voce.
-- ════════════════════════════════════════════════════════════════

insert into public.grape_varieties (name, rnv_number, berry_color, regions, synonyms, registration_date) values
  ('Abbuoto', 1, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Aglianico', 2, 'nera', array[]::text[], array['Aglianico del Vulture', 'Glianica', 'Glianico', 'Ellanico', 'Ellenico'], '1970-05-25'),
  ('Aglianicone', 3, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Albana', 4, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Albanello', 5, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Albaranzeuli Bianco', 6, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Albaranzeuli Nero', 7, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Albarola', 8, 'bianca', array[]::text[], array['Bianchetta Genovese'], '1970-05-25'),
  ('Aleatico', 9, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Alicante', 10, 'nera', array[]::text[], array['Cannonau', 'Tocai Rosso', 'Cannonao', 'Garnacha Tinta', 'Granaccia', 'Grenache', 'Guarnaccia', 'Gamay'], '1970-05-25'),
  ('Alicante Bouschet', 11, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Ancellotta', 12, 'nera', array[]::text[], array['Lancellotta'], '1970-05-25'),
  ('Ansonica', 13, 'bianca', array[]::text[], array['Inzolia', 'Insolia'], '1970-05-25'),
  ('Arneis', 14, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Arvesiniadu', 15, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Asprinio Bianco', 16, 'bianca', array[]::text[], array['Greco'], '1970-05-25'),
  ('Avana''', 17, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Avarengo', 18, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Barbera', 19, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Barbera Bianca', 20, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Barbera Sarda', 21, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Barsaglina', 22, 'nera', array[]::text[], array['Massaretta'], '1970-05-25'),
  ('Bellone', 23, 'bianca', array[]::text[], array['Cacchione'], '1970-05-25'),
  ('Bervedino', 24, 'bianca', array[]::text[], array['Vernaccia di S. Gimignano'], '1970-05-25'),
  ('Biancame', 25, 'bianca', array[]::text[], array['Trebbiano Toscano', 'Bianchello'], '1970-05-25'),
  ('Bianchetta Genovese', 26, 'bianca', array[]::text[], array['Albarola'], '1970-05-25'),
  ('Bianchetta Trevigiana', 27, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Bianco D''Alessano', 28, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Biancolella', 29, 'bianca', array[]::text[], array['Janculillo', 'Janculella'], '1970-05-25'),
  ('Biancone', 30, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Bombino Bianco', 32, 'bianca', array[]::text[], array['Ottenese', 'Bombino', 'Bonvino'], '1970-05-25'),
  ('Bombino Nero', 33, 'nera', array[]::text[], array['Bombino', 'Bonvino'], '1970-05-25'),
  ('Bonamico', 34, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Bonarda', 35, 'nera', array[]::text[], array['Uva Rara'], '1970-05-25'),
  ('Bosco', 36, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Bovale Grande', 37, 'nera', array[]::text[], array['Carignano', 'Bovale di Spagna', 'Bovale', 'Nerello Cappuccio'], '1970-05-25'),
  ('Bovale', 38, 'nera', array[]::text[], array['Bovaleddu'], '1970-05-25'),
  ('Bracciola Nera', 39, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Brachetto', 40, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Cabernet Franc', 42, 'nera', array[]::text[], array['Cabernet'], '1970-05-25'),
  ('Cabernet Sauvignon', 43, 'nera', array[]::text[], array['Cabernet'], '1970-05-25'),
  ('Caddiu', 44, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Cagnulari', 45, 'nera', array[]::text[], array['Cagniulari'], '1970-05-25'),
  ('Calabrese', 46, 'nera', array[]::text[], array['Nero D''Avola'], '1970-05-25'),
  ('Caloria', 47, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Canaiolo Bianco', 48, 'bianca', array[]::text[], array['Drupeggio', 'Canaiolo'], '1970-05-25'),
  ('Canaiolo Nero', 49, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Canina Nera', 50, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Cannonau', 51, 'nera', array[]::text[], array['Alicante', 'Tocai Rosso', 'Garnacha Tinta', 'Granaccia', 'Grenache', 'Cannonao', 'Gamay'], '1970-05-25'),
  ('Caricagiola', 52, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Carica L''Asino', 53, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Carignano', 54, 'nera', array[]::text[], array['Bovale Grande', 'Nerello Cappuccio'], '1970-05-25'),
  ('Carricante', 55, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Castiglione', 56, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Catanese Nero', 57, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Catarratto Bianco Comune', 58, 'bianca', array[]::text[], array['Catarratto', 'Lucido'], '1970-05-25'),
  ('Catarratto Bianco Lucido', 59, 'bianca', array[]::text[], array['Catarratto* Lucido'], '1970-05-25'),
  ('Cesanese Comune', 60, 'nera', array[]::text[], array['Cesanese'], '1970-05-25'),
  ('Cesanese d Affile', 61, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Ciliegiolo', 62, 'nera', array[]::text[], array['Morettone'], '1970-05-25'),
  ('Clairette', 63, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Cococciola', 64, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Coda di Volpe Bianca', 65, 'bianca', array[]::text[], array['Coda di Volpe'], '1970-05-25'),
  ('Colombana Nera', 66, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Colorino', 67, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Corinto Nero', 68, 'nera', array[]::text[], array[]::text[], '1971-03-01'),
  ('Cortese', 69, 'bianca', array[]::text[], array['Bianca Fernanda'], '1970-05-25'),
  ('Corvina', 70, 'nera', array[]::text[], array['Cruina'], '1970-05-25'),
  ('Croatina', 71, 'nera', array[]::text[], array['Bonarda'], '1970-05-25'),
  ('Damaschino', 72, 'bianca', array[]::text[], array['Vujino'], '1971-03-22'),
  ('Dolcetto', 73, 'nera', array[]::text[], array['Ormeasco'], '1970-05-25'),
  ('Dolciame', 74, 'bianca', array[]::text[], array[]::text[], '1971-02-22'),
  ('Doux D''Henry', 75, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Durasa', 76, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Durella', 77, 'bianca', array[]::text[], array['Durello'], '1970-05-25'),
  ('Erbaluce', 78, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Falanghina', 79, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Favorita', 80, 'bianca', array[]::text[], array['Pigato', 'Vermentino'], '1970-05-25'),
  ('Fiano', 81, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Foglia Tonda', 82, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Forastera', 83, 'bianca', array[]::text[], array['Forestiera', 'Furastiera'], '1970-05-25'),
  ('Fortana', 84, 'nera', array[]::text[], array['Uva D''Oro'], '1970-05-25'),
  ('Francavidda', 85, 'bianca', array[]::text[], array['Francavilla'], '1970-05-25'),
  ('Franconia', 86, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Frappato', 87, 'nera', array[]::text[], array['Frappato D'' Italia'], '1970-05-25'),
  ('Freisa', 88, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Fumin', 89, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Gaglioppo', 90, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Gamay', 91, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Garganega', 92, 'bianca', array[]::text[], array['Grecanico Dorato', 'Garganego'], '1970-05-25'),
  ('Giro''', 93, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Grecanico Dorato', 94, 'bianca', array[]::text[], array['Garganega'], '1970-05-25'),
  ('Grechetto', 95, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Grechetto Rosso', 96, 'nera', array[]::text[], array['Sangiovese'], '1971-02-22'),
  ('Greco', 97, 'bianca', array[]::text[], array['Asprinio Bianco'], '1970-05-25'),
  ('Greco Bianco', 98, 'bianca', array[]::text[], array['Guardavalle', 'Greco'], '1970-05-25'),
  ('Greco Nero', 99, 'nera', array[]::text[], array['Marsigliana', 'Magliocco Dolce', 'Arvino', 'Greco'], '1970-05-25'),
  ('Grignolino', 100, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Grillo', 101, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Groppello di Mocasina', 102, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Groppello di S. Stefano', 103, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Groppello Gentile', 104, 'nera', array[]::text[], array['Groppello'], '1970-05-25'),
  ('Guardavalle', 105, 'bianca', array[]::text[], array['Greco Bianco', 'Uva Greca'], '1971-03-22'),
  ('Guarnaccia', 106, 'bianca', array[]::text[], array['Granatza'], '1970-05-25'),
  ('Impigno', 107, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Incrocio Bruni 54', 108, 'bianca', array[]::text[], array[]::text[], '1971-02-22'),
  ('Incrocio Manzoni 2.15', 109, 'nera', array[]::text[], array['Manzoni Rosso'], '1970-05-25'),
  ('Incrocio Terzi N.1', 110, 'nera', array[]::text[], array['Gratena'], '1970-05-25'),
  ('Lacrima', 111, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Lagrein', 112, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Lambrusca di Alessandria', 113, 'nera', array[]::text[], array[]::text[], '1974-04-17'),
  ('Lambrusco A Foglia Frastagliata', 114, 'nera', array[]::text[], array['Enantio'], '1970-05-25'),
  ('Lambrusco di Sorbara', 115, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Lambrusco Grasparossa', 116, 'nera', array[]::text[], array['Groppello Grasparossa', 'Lambrusco'], '1970-05-25'),
  ('Lambrusco Maestri', 117, 'nera', array[]::text[], array['Groppello Maestri', 'Lambrusco'], '1970-05-25'),
  ('Lambrusco Marani', 118, 'nera', array[]::text[], array['Lambrusco'], '1970-05-25'),
  ('Lambrusco Montericco', 119, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Lambrusco Salamino', 120, 'nera', array[]::text[], array['Lambrusco'], '1970-05-25'),
  ('Lambrusco Viadanese', 121, 'nera', array[]::text[], array['Grappello Ruberti'], '1970-05-25'),
  ('Livornese Bianca', 122, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Lumassina', 123, 'bianca', array[]::text[], array['Buzzetto', 'Mataosso', 'Mataossu'], '1971-03-22'),
  ('Maceratino', 124, 'bianca', array[]::text[], array['Ribona'], '1970-05-25'),
  ('Magliocco Canino', 125, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Maiolica', 126, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Malbech', 127, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Malvasia', 128, 'nera', array[]::text[], array['Malvasier', 'Roter Malvasier*;'], '1971-03-22'),
  ('Malvasia Bianca', 129, 'bianca', array[]::text[], array['Verdana', 'Iuvarella', 'Malvasia'], '1971-02-22'),
  ('Malvasia Bianca di Basilicata', 130, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Malvasia Bianca di Candia', 131, 'bianca', array[]::text[], array['Malvasia', 'Malvoisie', 'Malvoisier'], '1970-05-25'),
  ('Malvasia Bianca Lunga', 132, 'bianca', array[]::text[], array['Malvasia', 'Malvoisie', 'Malvoisier'], '1970-05-25'),
  ('Malvasia del Lazio', 133, 'bianca', array[]::text[], array['Malvasia Puntinata'], '1970-05-25'),
  ('Malvasia di Casorzo', 134, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Malvasia di Lipari', 135, 'bianca', array[]::text[], array['Malvasia di Sardegna'], '1970-05-25'),
  ('Malvasia di Sardegna', 136, 'bianca', array[]::text[], array['Malvasia di Lipari'], '1970-05-25'),
  ('Malvasia di Schierano', 137, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Malvasia Istriana', 138, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Malvasia Nera di Basilicata', 139, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Malvasia Nera di Brindisi', 140, 'nera', array[]::text[], array['Malvasia Nera di Lecce', 'Malvasia', 'Malvoisie', 'Malvoisier'], '1970-05-25'),
  ('Malvasia Nera di Lecce', 141, 'nera', array[]::text[], array['Malvasia Nera di Brindisi', 'Malvasia', 'Malvoisie', 'Malvoisier'], '1970-05-25'),
  ('Mammolo', 142, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Marsigliana Nera', 143, 'nera', array[]::text[], array['Greco Nero', 'Magliocco Dolce', 'Arvino.'], '1971-02-22'),
  ('Marzemino', 144, 'nera', array[]::text[], array['Berzemino'], '1970-05-25'),
  ('Mazzese', 145, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Merlot', 146, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Minnella Bianca', 147, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Molinara', 148, 'nera', array[]::text[], array['Rossano', 'Rossanella'], '1970-05-25'),
  ('Monica', 149, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Montepulciano', 150, 'nera', array[]::text[], array['Cordisco'], '1970-05-25'),
  ('Montonico Bianco', 151, 'bianca', array[]::text[], array['Uva della Scala'], '1970-05-25'),
  ('Montu''', 152, 'bianca', array[]::text[], array['Montuni'], '1970-05-25'),
  ('Moscato Bianco', 153, 'bianca', array[]::text[], array['Muscat Blanc A Petit Grain', 'Muscat De Chambave', 'Moscato', 'Moscatello', 'Moscatellone', 'Muscat', 'Muskateller', 'Moscato Reale', 'Gelber Muskateller'], '1970-05-25'),
  ('Moscato Giallo', 154, 'bianca', array[]::text[], array['Moscato', 'Moscatello', 'Moscatellone', 'Goldmuskateller', 'Muscat', 'Muskateller'], '1970-05-25'),
  ('Moscato Nero di Acqui', 155, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Moscato Rosa', 156, 'rosa', array[]::text[], array['Moscato delle Rose', 'Rosenmuskateller'], '1971-03-22'),
  ('Mostosa', 157, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Muller Thurgau', 158, 'bianca', array[]::text[], array['Weisser Riesling X Madeleine Royale'], '1970-05-25'),
  ('Nasco', 159, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Nebbiolo', 160, 'nera', array[]::text[], array['Spanna', 'Chiavennasca', 'Prunent'], '1970-05-25'),
  ('Negrara', 161, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Negretto', 162, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Negro Amaro', 163, 'nera', array[]::text[], array['Negroamaro', 'Nero Amaro'], '1970-05-25'),
  ('Nerello Cappuccio', 164, 'nera', array[]::text[], array['Nerello Mantellato', 'Bovale Grande', 'Carignano'], '1970-05-25'),
  ('Nerello Mascalese', 165, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Neretta Cuneese', 166, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Neretto di Bairo', 167, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Nero Buono', 168, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Neyret', 169, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Nieddera', 170, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Nieddu Mannu', 171, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Nocera', 172, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Nosiola', 173, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Notardomenico', 174, 'nera', array[]::text[], array['San Nicola'], '1971-03-22'),
  ('Nuragus', 175, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Olivella Nera', 176, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Ortrugo', 177, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Ottavianello', 178, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Pampanuto', 179, 'bianca', array[]::text[], array['Pampanino', 'Verdeca'], '1971-03-22'),
  ('Pascale', 180, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Passerina', 181, 'bianca', array[]::text[], array[]::text[], '1971-02-22'),
  ('Pavana', 182, 'nera', array[]::text[], array['Saccola'], '1970-05-25'),
  ('Pecorello', 183, 'bianca', array[]::text[], array[]::text[], '1971-02-22'),
  ('Pecorino', 184, 'bianca', array[]::text[], array['Vissanello'], '1970-05-25'),
  ('Perricone', 185, 'nera', array[]::text[], array['Pignatello', 'Balbino'], '1970-05-25'),
  ('Petit Rouge', 186, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Piccola Nera', 187, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Picolit', 188, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Piedirosso', 189, 'nera', array[]::text[], array['Piede di Colombo', 'Piede di Palumbo', 'Per'' e Palummo', 'Palombina'], '1970-05-25'),
  ('Pigato', 190, 'bianca', array[]::text[], array['Favorita', 'Vermentino'], '1970-05-25'),
  ('Pignola', 191, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Pinella', 192, 'bianca', array[]::text[], array['Pinella Bianca', 'Pinello'], '1970-05-25'),
  ('Pinot Bianco', 193, 'bianca', array[]::text[], array['Wei'], '1970-05-25'),
  ('Pinot Grigio', 194, 'grigia', array[]::text[], array['Rulander', 'Pinot Gris', 'Pinot', 'Grauer Burgunder', 'Grauburgunder'], '1970-05-25'),
  ('Pinot Nero', 195, 'nera', array[]::text[], array['Blau Burgunder* ; Spatburgunder', 'Blauer Spatburgunder', 'Pinot Noir', 'Pinot'], '1970-05-25'),
  ('Plassa', 196, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Pollera Nera', 197, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Portoghese', 198, 'nera', array[]::text[], array['Blauer Portugieser', 'Portugieser'], '1971-03-22'),
  ('Primitivo', 199, 'nera', array[]::text[], array['Zinfandel'], '1970-05-25'),
  ('Glera', 200, 'bianca', array[]::text[], array['Serprino'], '1970-05-25'),
  ('Prugnolo Gentile', 201, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Prunesta', 202, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Raboso Piave', 203, 'nera', array[]::text[], array['Friularo'], '1970-05-25'),
  ('Raboso Veronese', 204, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Refosco dal Peduncolo Rosso', 205, 'nera', array[]::text[], array['Refosco', 'Malvoise'], '1971-03-22'),
  ('Refosco Nostrano', 206, 'nera', array[]::text[], array['Refosco', 'Refosco Grosso', 'Refoscone', 'Malvoise'], '1971-03-22'),
  ('Retagliado Bianco', 207, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Ribuele', 208, 'bianca', array[]::text[], array['Ribolla Gialla', 'Ribolla', 'Rebula'], '1970-05-25'),
  ('Riesling Italico', 209, 'bianca', array[]::text[], array['Welschriesling', 'Riesling'], '1970-05-25'),
  ('Riesling Renano', 210, 'bianca', array[]::text[], array['Rheinriesling', 'Riesling'], '1970-05-25'),
  ('Rollo', 211, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Rondinella', 212, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Rossese', 213, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Rossignola', 214, 'nera', array[]::text[], array['Rossetta'], '1970-05-25'),
  ('Rossola Nera', 215, 'nera', array[]::text[], array['Rossola'], '1970-05-25'),
  ('Roussane', 216, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Sagrantino', 217, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Sangiovese', 218, 'nera', array[]::text[], array['Sangioveto', 'Grechetto Rosso'], '1970-05-25'),
  ('S. Giuseppe Nero', 219, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('S. Lunardo', 220, 'bianca', array[]::text[], array[]::text[], '1971-02-22'),
  ('Sauvignon', 221, 'bianca', array[]::text[], array['Sauvignon Blanc'], '1970-05-25'),
  ('Schiava Gentile', 222, 'nera', array[]::text[], array['Schiava', 'Vernatsch', 'Kleinvernatsch', 'Mittervernatsch'], '1970-05-25'),
  ('Schiava Grigia', 223, 'nera', array[]::text[], array['Schiava', 'Vernatsch', 'Grauvernatsch'], '1970-05-25'),
  ('Schiava', 224, 'nera', array[]::text[], array['Erbanno'], '1970-05-25'),
  ('Sciascinoso', 225, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Semidano', 226, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Semillon', 227, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Sgavetta', 228, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Susumaniello', 229, 'nera', array[]::text[], array['Sussumariello'], '1974-04-17'),
  ('Sylvaner Verde', 230, 'bianca', array[]::text[], array['Gruner Sylvaner** ; Silvaner', 'Sylvaner'], '1970-05-25'),
  ('Syrah', 231, 'nera', array[]::text[], array['Shiraz'], '1970-05-25'),
  ('Teroldego', 232, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Terrano', 233, 'nera', array[]::text[], array['Cagnina', 'Teran', 'Lambrusco dal Peduncolo Rosso', 'Refo?k'], '1970-05-25'),
  ('Timorasso', 234, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Tocai Friulano', 235, 'bianca', array[]::text[], array['Friulano', 'Tai', 'Tuchi'''], '1970-05-25'),
  ('Tocai Rosso', 236, 'nera', array[]::text[], array['Alicante', 'Cannonau', 'Cannonao', 'Garnacha Tinta', 'Granaccia', 'Grenache', 'Tai Rosso'], '1970-05-25'),
  ('Torbato', 237, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Traminer Aromatico', 238, 'rosa', array[]::text[], array['Gewurztraminer'], '1970-05-25'),
  ('Trebbiano di Soave', 239, 'bianca', array[]::text[], array['Verdicchio Bianco', 'Turbiana', 'Trebbiano di Lugana'], '1970-05-25'),
  ('Trebbiano Giallo', 240, 'bianca', array[]::text[], array['Rossetto', 'Trebbiano'], '1970-05-25'),
  ('Trebbiano Modenese', 241, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Trebbiano Romagnolo', 242, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Trebbiano Spoletino', 243, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Trebbiano Toscano', 244, 'bianca', array[]::text[], array['Biancame', 'Procanico', 'Ugni Blanc'], '1970-05-25'),
  ('Trevisana Nera', 245, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Turca', 246, 'nera', array[]::text[], array['Serbina'], '1970-05-25'),
  ('Uva di Troia', 247, 'nera', array[]::text[], array['Sumarello', 'Sommarrello', 'Nero di Troia'], '1970-05-25'),
  ('Uva Rara', 248, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Uva Tosca', 249, 'nera', array[]::text[], array[]::text[], '1971-03-22'),
  ('Veltliner', 250, 'bianca', array[]::text[], array['Gruner Veltliner'], '1971-03-22'),
  ('Verdea', 251, 'bianca', array[]::text[], array['Colombana Bianca'], '1970-05-25'),
  ('Verdeca', 252, 'bianca', array[]::text[], array['Pampanuto'], '1970-05-25'),
  ('Verdello', 253, 'bianca', array[]::text[], array['Verdicchio Bianco', 'Verduschia'], '1971-02-22'),
  ('Verdicchio Bianco', 254, 'bianca', array[]::text[], array['Trebbiano di Lugana', 'Trebbiano di Soave', 'Verdello', 'Verduschia', 'Peverella', 'Trebbiano Verde'], '1970-05-25'),
  ('Verdiso', 255, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Verduzzo Friulano', 256, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Verduzzo Trevigiano', 257, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Vermentino', 258, 'bianca', array[]::text[], array['Pigato', 'Favorita'], '1970-05-25'),
  ('Vermentino Nero', 259, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Vernaccia di Oristano', 260, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Vernaccia di S. Gimignano', 261, 'bianca', array[]::text[], array['Bervedino'], '1970-05-25'),
  ('Vernaccia Nera', 262, 'nera', array[]::text[], array['Vernaccia'], '1970-05-25'),
  ('Vespaiola', 263, 'bianca', array[]::text[], array['Vespaiolo'], '1970-05-25'),
  ('Vespolina', 264, 'nera', array[]::text[], array['Ughetta'], '1970-05-25'),
  ('Vien De Nus', 265, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('Aglianico del Vulture', 266, 'nera', array[]::text[], array['Aglianico'], '1971-03-22'),
  ('Albarossa', 267, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Bric', 268, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Bussanello', 269, 'bianca', array[]::text[], array[]::text[], '1977-06-20'),
  ('Chasselas Dorato', 270, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('Cornarea', 271, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Cove''', 272, 'bianca', array[]::text[], array[]::text[], '1977-06-20'),
  ('Fertilia', 273, 'nera', array[]::text[], array[]::text[], '1976-01-26'),
  ('Flavis', 274, 'bianca', array[]::text[], array[]::text[], '1976-01-26'),
  ('Fubiano', 275, 'bianca', array[]::text[], array[]::text[], '1977-06-20'),
  ('Incrocio Bianco Fedit 51 C.s.g.', 276, 'bianca', array[]::text[], array['Dorona'], '1976-01-28'),
  ('Invernenga', 277, 'bianca', array[]::text[], array[]::text[], '1971-03-22'),
  ('Italica', 278, 'bianca', array[]::text[], array[]::text[], '1976-01-26'),
  ('Malvasia di Candia Aromatica', 279, 'bianca', array[]::text[], array[]::text[], '1970-05-25'),
  ('S. Martino', 280, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Moscato di Terracina', 281, 'bianca', array[]::text[], array['Moscatello', 'Moscatellone', 'Muscat', 'Muskateller'], '1971-02-22'),
  ('Nebbiera', 282, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Nigra', 283, 'nera', array[]::text[], array[]::text[], '1976-01-26'),
  ('Passau', 284, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Pignolo', 285, 'nera', array[]::text[], array[]::text[], '1977-06-14'),
  ('Prodest', 286, 'nera', array[]::text[], array[]::text[], '1976-01-26'),
  ('Rossara', 287, 'nera', array[]::text[], array[]::text[], '1970-05-25'),
  ('S. Michele', 288, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Schiava Grossa', 289, 'nera', array[]::text[], array['Edelvernatsch', 'Grossevernatsch', 'Schiava', 'Vernatsch'], '1970-05-25'),
  ('Schioppettino', 290, 'nera', array[]::text[], array[]::text[], '1977-06-14'),
  ('Sirio', 291, 'bianca', array[]::text[], array[]::text[], '1977-06-20'),
  ('Soperga', 292, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Tazzelenghe', 293, 'nera', array[]::text[], array[]::text[], '1977-06-14'),
  ('Tschaggele', 294, 'nera', array[]::text[], array[]::text[], '1971-02-22'),
  ('Valentino', 295, 'nera', array[]::text[], array[]::text[], '1977-06-20'),
  ('Vega', 296, 'bianca', array[]::text[], array[]::text[], '1977-06-20'),
  ('Verduschia', 297, 'bianca', array[]::text[], array['Verdello', 'Verdicchio Bianco'], '1971-03-22'),
  ('Chardonnay', 298, 'bianca', array[]::text[], array[]::text[], '1978-10-24'),
  ('Manzoni Bianco', 299, 'bianca', array[]::text[], array['Incrocio Manzoni 6.0.13'], '1978-09-18'),
  ('Pignoletto', 300, 'bianca', array[]::text[], array['Grechetto Gentile', 'Alionzina', 'Grechetto'], '1978-09-18'),
  ('Rebo', 301, 'nera', array[]::text[], array[]::text[], '1978-09-18'),
  ('Meunier', 302, 'nera', array[]::text[], array[]::text[], '1980-10-01'),
  ('Wildbacher', 303, 'nera', array[]::text[], array[]::text[], '1980-10-01'),
  ('Cornalin', 304, null, array[]::text[], array[]::text[], '1981-05-06'),
  ('Kerner', 305, 'bianca', array[]::text[], array[]::text[], '1981-05-06'),
  ('Mayolet', 306, 'nera', array[]::text[], array[]::text[], '1981-05-06'),
  ('Moscatello Selvatico', 307, 'bianca', array[]::text[], array[]::text[], '1981-05-06'),
  ('Moscato di Scanzo', 308, 'nera', array[]::text[], array[]::text[], '1981-05-06'),
  ('Pelaverga', 309, 'nera', array[]::text[], array['Cari'], '1981-05-06'),
  ('Petite Arvine', 310, 'bianca', array[]::text[], array[]::text[], '1981-05-06'),
  ('Prie Blanc', 311, 'bianca', array[]::text[], array[]::text[], '1981-05-06'),
  ('Prie Rouge', 312, 'rosa', array[]::text[], array[]::text[], '1981-05-06'),
  ('Ruche''', 313, 'nera', array[]::text[], array[]::text[], '1981-05-06'),
  ('Canaiolo Rosa', 314, 'rosa', array[]::text[], array[]::text[], '1982-08-03'),
  ('Alionza', 315, 'bianca', array[]::text[], array[]::text[], '1987-07-21'),
  ('Dindarella', 316, 'nera', array[]::text[], array[]::text[], '1987-07-23'),
  ('Forsellina', 317, 'nera', array[]::text[], array[]::text[], '1987-07-23'),
  ('Malvasia Rosa', 318, 'rosa', array[]::text[], array[]::text[], '1991-03-02'),
  ('Marsanne', 319, 'bianca', array[]::text[], array[]::text[], '1991-03-11'),
  ('Vitouska', 320, 'bianca', array[]::text[], array['Garganja', 'Vitovska'], '1990-08-31'),
  ('Forgiarin', 321, 'nera', array[]::text[], array[]::text[], '1992-01-20'),
  ('Piculit-Neri', 322, 'nera', array[]::text[], array[]::text[], '1992-01-20'),
  ('Sciaglin', 323, 'bianca', array[]::text[], array[]::text[], '1992-01-20'),
  ('Ucelut', 324, 'bianca', array[]::text[], array[]::text[], '1992-01-20'),
  ('Quagliano', 325, 'nera', array[]::text[], array[]::text[], '1992-06-24'),
  ('Boschera', 326, 'bianca', array[]::text[], array[]::text[], '1992-10-30'),
  ('Corvinone', 328, 'nera', array[]::text[], array[]::text[], '1993-07-15'),
  ('Marzemina Bianca', 329, 'bianca', array[]::text[], array['Marzemina'], '1994-11-24'),
  ('Pelaverga Piccolo', 330, 'nera', array[]::text[], array[]::text[], '1994-11-24'),
  ('Perera', 331, 'bianca', array[]::text[], array[]::text[], '1994-11-24'),
  ('Trebbiano Abruzzese', 332, 'bianca', array[]::text[], array[]::text[], '1994-11-24'),
  ('Malbo Gentile', 333, 'nera', array[]::text[], array[]::text[], '1995-03-03'),
  ('Pedevenda', 334, 'bianca', array[]::text[], array[]::text[], '1995-03-03'),
  ('Petit Verdot', 335, 'nera', array[]::text[], array[]::text[], '1995-03-03'),
  ('Carmenere', 336, 'nera', array[]::text[], array['Cabernet Nostrano', 'Cabernet Italiano', 'Cabernet'], '1996-11-18'),
  ('Verdese', 337, 'bianca', array[]::text[], array[]::text[], '1996-11-18'),
  ('Ervi', 338, 'nera', array[]::text[], array[]::text[], '1999-03-01'),
  ('Melara', 339, 'bianca', array[]::text[], array[]::text[], '1999-03-01'),
  ('Santa Maria', 340, 'bianca', array[]::text[], array[]::text[], '1999-03-01'),
  ('Regina', 341, 'bianca', array[]::text[], array[]::text[], '1999-10-11'),
  ('Regina dei Vigneti', 342, 'bianca', array[]::text[], array[]::text[], '1999-10-11'),
  ('Zibibbo', 343, 'bianca', array[]::text[], array['Moscato d Alessandria', 'Duraca', 'Moscato', 'Moscatello', 'Moscatellone'], '1999-10-11'),
  ('Tannat', 344, 'nera', array[]::text[], array[]::text[], '1999-03-01'),
  ('Tempranillo', 345, 'nera', array[]::text[], array[]::text[], '1999-03-01'),
  ('Viognier', 346, 'bianca', array[]::text[], array[]::text[], '1999-03-01'),
  ('Abrusco', 347, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Bonda', 348, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Crovassa', 349, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Diolinoir', 350, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Gamaret', 351, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Garanoir', 352, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Morone', 353, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Ner D''Ala', 354, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Roussin', 355, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Vuillermin', 356, 'nera', array[]::text[], array[]::text[], '1999-10-11'),
  ('Uva Longanesi', 357, 'nera', array[]::text[], array[]::text[], '2000-12-06'),
  ('Oseleta', 358, 'nera', array[]::text[], array[]::text[], '2000-12-06'),
  ('Glera Lunga', 359, 'bianca', array[]::text[], array['Glera', 'Serprino'], '2000-12-06'),
  ('Lambrusco Oliva', 360, 'nera', array[]::text[], array[]::text[], '2000-12-06'),
  ('Negroamaro Precoce', 361, 'nera', array[]::text[], array[]::text[], '2000-12-06'),
  ('Nascetta', 362, 'bianca', array[]::text[], array[]::text[], '2001-11-06'),
  ('Malvasia Nera Lunga', 363, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Spergola', 364, 'bianca', array[]::text[], array[]::text[], '2002-05-15'),
  ('Casavecchia', 365, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Sennen', 366, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Gosen', 367, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Goldtraminer', 368, 'bianca', array[]::text[], array[]::text[], '2002-05-15'),
  ('Casetta', 369, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Uvalino', 370, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Pugnitello', 371, 'nera', array[]::text[], array[]::text[], '2002-05-15'),
  ('Tintilia', 372, 'nera', array[]::text[], array[]::text[], '2002-11-27'),
  ('Becuet', 373, 'nera', array[]::text[], array[]::text[], '2003-07-09'),
  ('Rossese Bianco', 374, 'bianca', array[]::text[], array[]::text[], '2003-07-09'),
  ('Manzoni Moscato', 375, 'nera', array[]::text[], array['Incrocio Manzoni 13.0.25'], '2003-07-09'),
  ('Manzoni Rosa', 376, 'rosa', array[]::text[], array['Incrocio Manzoni 1-50'], '2003-07-09'),
  ('Scimiscia''', 377, 'bianca', array[]::text[], array[]::text[], '2003-07-09'),
  ('Centesimino', 378, 'nera', array[]::text[], array[]::text[], '2004-05-07'),
  ('Chatus', 379, 'nera', array[]::text[], array[]::text[], '2004-05-07'),
  ('Groppello di Revo', 380, 'nera', array[]::text[], array[]::text[], '2004-05-07'),
  ('Pallagrello Bianco', 381, 'bianca', array[]::text[], array[]::text[], '2004-05-07'),
  ('Pallagrello Nero', 382, 'nera', array[]::text[], array[]::text[], '2004-05-07'),
  ('Fenile', 383, 'bianca', array[]::text[], array[]::text[], '2005-06-09'),
  ('Ginestra', 384, 'bianca', array[]::text[], array[]::text[], '2005-06-09'),
  ('Pepella', 385, 'bianca', array[]::text[], array[]::text[], '2005-06-09'),
  ('Ripolo', 386, 'bianca', array[]::text[], array[]::text[], '2005-06-09'),
  ('Tronto', 387, 'nera', array[]::text[], array[]::text[], '2005-06-09'),
  ('Cividin', 388, 'bianca', array[]::text[], array[]::text[], '2006-02-02'),
  ('Mondeuse', 389, 'nera', array[]::text[], array[]::text[], '2006-02-02'),
  ('Cjanorie', 390, 'nera', array[]::text[], array[]::text[], '2006-02-02'),
  ('Chenin', 391, 'bianca', array[]::text[], array[]::text[], '2006-02-02'),
  ('Moradella', 392, 'nera', array[]::text[], array[]::text[], '2006-02-02'),
  ('Fogarina', 393, 'nera', array[]::text[], array[]::text[], '2007-01-09'),
  ('Perla dei Vivi', 394, 'nera', array[]::text[], array[]::text[], '2007-01-09'),
  ('Termarina', 395, 'nera', array[]::text[], array[]::text[], '2007-01-09'),
  ('Zweigelt', 396, 'nera', array[]::text[], array[]::text[], '2007-01-09'),
  ('Orpicchio', 397, 'bianca', array[]::text[], array[]::text[], '2007-01-09'),
  ('Catalanesca', 398, 'bianca', array[]::text[], array[]::text[], '2007-01-09'),
  ('Lagarino', 399, 'bianca', array[]::text[], array[]::text[], '2007-01-09'),
  ('Merlese', 400, 'nera', array[]::text[], array[]::text[], '2007-01-09'),
  ('Verdealbara', 401, 'bianca', array[]::text[], array['Erbamat'], '2007-01-09'),
  ('Petit Manseng', 402, 'bianca', array[]::text[], array[]::text[], '2007-01-09'),
  ('Gamba Rossa', 403, 'nera', array[]::text[], array['Imperatrice Dalla Gamba Rossa'], '2007-09-19'),
  ('Lambrusco Barghi', 404, 'nera', array[]::text[], array[]::text[], '2007-09-19'),
  ('Cavrara', 405, 'nera', array[]::text[], array[]::text[], '2007-09-19'),
  ('Corbina', 406, 'nera', array[]::text[], array['Corbinella'], '2007-09-19'),
  ('Grapariol', 407, 'bianca', array[]::text[], array[]::text[], '2007-09-19'),
  ('Marzemina Grossa', 408, 'nera', array[]::text[], array['Marzemina Bastarda'], '2007-09-19'),
  ('Recantina', 409, 'nera', array[]::text[], array[]::text[], '2007-09-19'),
  ('Turchetta', 410, 'nera', array[]::text[], array[]::text[], '2007-09-19'),
  ('Slarina', 411, 'nera', array[]::text[], array[]::text[], '2007-09-19'),
  ('Sanforte', 412, 'nera', array[]::text[], array[]::text[], '2007-09-19'),
  ('Baratuciat', 413, 'bianca', array[]::text[], array[]::text[], '2008-06-23'),
  ('Cordenossa', 414, 'nera', array[]::text[], array[]::text[], '2008-06-23'),
  ('Vernaccia Nera Grossa', 415, 'nera', array[]::text[], array[]::text[], '2008-06-23'),
  ('Bronner', 416, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Capolongo', 417, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Erbamat', 418, 'bianca', array[]::text[], array['Verdealbara'], '2009-03-27'),
  ('Erbanno', 419, 'nera', array[]::text[], array['Schiava'], '2009-03-27'),
  ('Famoso', 420, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Lecinaro', 421, 'nera', array[]::text[], array[]::text[], '2009-03-27'),
  ('Maiolina', 422, 'nera', array[]::text[], array[]::text[], '2009-03-27'),
  ('Maor', 423, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Maturano', 424, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Moscato Ottonel', 425, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Pampanaro', 426, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Paolina', 427, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Regent', 428, 'nera', array[]::text[], array[]::text[], '2009-03-27'),
  ('Rosciola', 429, 'rosa', array[]::text[], array[]::text[], '2009-03-27'),
  ('Roviello', 430, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Ruggine', 431, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Ruzzese', 432, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Serbina', 433, 'nera', array[]::text[], array['Turca'], '2009-03-27'),
  ('Trebbianina', 434, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Uva del Fantini', 435, 'nera', array[]::text[], array[]::text[], '2009-03-27'),
  ('Uva del Tunde''', 436, 'nera', array[]::text[], array[]::text[], '2009-03-27'),
  ('Vernaccina', 437, 'bianca', array[]::text[], array[]::text[], '2009-03-27'),
  ('Veruccese', 438, 'nera', array[]::text[], array[]::text[], '2009-03-27'),
  ('Celtica', 439, 'bianca', array[]::text[], array[]::text[], '2010-05-28'),
  ('Gratena', 440, 'nera', array[]::text[], array['Incrocio Terzi N.1'], '2010-05-28'),
  ('Mornasca', 441, 'nera', array[]::text[], array[]::text[], '2010-05-28'),
  ('Pliniana', 442, 'nera', array[]::text[], array[]::text[], '2010-05-28'),
  ('Rossone', 443, 'nera', array[]::text[], array[]::text[], '2010-05-28'),
  ('Tintore', 444, 'nera', array[]::text[], array[]::text[], '2010-05-28'),
  ('Virgilio', 445, 'bianca', array[]::text[], array[]::text[], '2010-05-28'),
  ('Antinello', 446, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Cornacchia', 447, 'nera', array[]::text[], array[]::text[], '2011-04-22'),
  ('Grero', 448, 'nera', array[]::text[], array['Grero'], '2011-04-22'),
  ('Incrocio Manzoni 2-14', 449, 'nera', array[]::text[], array[]::text[], '2011-04-22'),
  ('Incrocio Manzoni 2-3', 450, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Lambrusco Benetti', 451, 'nera', array[]::text[], array[]::text[], '2011-04-22'),
  ('Lanzesa', 452, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Marchione', 453, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Maresco', 454, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Minutolo', 455, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Pelagos', 456, 'nera', array[]::text[], array[]::text[], '2011-04-22'),
  ('Saint Laurent', 457, 'nera', array[]::text[], array[]::text[], '2011-04-22'),
  ('Scarsafoglia', 458, 'bianca', array[]::text[], array[]::text[], '2011-04-22'),
  ('Somarello Rosso', 459, 'nera', array[]::text[], array[]::text[], '2011-04-22'),
  ('Dorona', 460, 'bianca', array[]::text[], array['Incrocio Bianco Fedit 51 C.s.g.'], '2012-03-23'),
  ('Gruaja', 461, 'nera', array[]::text[], array[]::text[], '2012-03-23'),
  ('Malvasia Moscata', 462, 'bianca', array[]::text[], array[]::text[], '2012-03-23'),
  ('Garofanata', 463, 'bianca', array[]::text[], array[]::text[], '2012-11-22'),
  ('Grado''', 464, 'bianca', array[]::text[], array[]::text[], '2012-11-22'),
  ('Cabernet Carbon', 465, 'nera', array[]::text[], array[]::text[], '2013-07-10'),
  ('Cabernet Cortis', 466, 'nera', array[]::text[], array[]::text[], '2013-07-10'),
  ('Guarnaccino', 467, 'nera', array[]::text[], array[]::text[], '2013-07-10'),
  ('Helios', 468, 'bianca', array[]::text[], array[]::text[], '2013-07-10'),
  ('Johanniter', 469, 'bianca', array[]::text[], array[]::text[], '2013-07-10'),
  ('Prior', 470, 'nera', array[]::text[], array[]::text[], '2013-07-10'),
  ('Solaris', 471, 'bianca', array[]::text[], array[]::text[], '2013-07-10'),
  ('Spigamonti', 472, 'nera', array[]::text[], array[]::text[], '2013-07-10'),
  ('Biancaccia', 473, 'bianca', array[]::text[], array[]::text[], '2013-09-27'),
  ('Grappello Ruberti', 474, 'nera', array[]::text[], array['Lambrusco Viadanese'], '2013-09-27'),
  ('Rossetta di Montagna', 475, 'rosa', array[]::text[], array[]::text[], '2013-09-27'),
  ('Albarino', 476, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Arinarnoa', 477, 'nera', array[]::text[], array[]::text[], '2014-05-15'),
  ('Cesenese Nero', 478, 'nera', array[]::text[], array[]::text[], '2014-05-15'),
  ('Fumat', 479, 'nera', array[]::text[], array[]::text[], '2014-05-15'),
  ('Iasma Eco 1', 480, 'nera', array[]::text[], array[]::text[], '2014-05-15'),
  ('Iasma Eco 2', 481, 'nera', array[]::text[], array[]::text[], '2014-05-15'),
  ('Iasma Eco 3', 482, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Iasma Eco 4', 483, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Irsai Oliver', 484, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Marselan', 485, 'nera', array[]::text[], array[]::text[], '2014-05-15'),
  ('Palava', 486, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Refosco Bianco', 487, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Sagrestana', 488, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Verdejo', 489, 'bianca', array[]::text[], array[]::text[], '2014-05-15'),
  ('Bellagna', 490, 'nera', array[]::text[], array['Uva Cagna'], '2014-10-20'),
  ('Bragat Rosa', 491, 'nera', array[]::text[], array[]::text[], '2014-10-20'),
  ('Cabrusina', 492, 'nera', array[]::text[], array[]::text[], '2014-10-20'),
  ('Caprettone', 493, 'bianca', array[]::text[], array[]::text[], '2014-10-20'),
  ('Mantonico Bianco', 494, 'bianca', array[]::text[], array[]::text[], '2014-10-20'),
  ('Muscaris', 495, 'bianca', array[]::text[], array[]::text[], '2014-10-20'),
  ('Souvignier Gris', 496, 'bianca', array[]::text[], array[]::text[], '2014-10-20'),
  ('Fleurtai', 497, 'bianca', array[]::text[], array['Ud-34.111'], '2015-04-03'),
  ('Julius', 498, 'nera', array[]::text[], array['Ud-36.030'], '2015-04-03'),
  ('Montanera', 499, 'nera', array[]::text[], array[]::text[], '2015-04-03'),
  ('Soreli', 500, 'bianca', array[]::text[], array['Ud-34.113'], '2015-04-03'),
  ('Alvarega', 831, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Argu Mannu', 832, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Bian Ver', 833, 'bianca', array[]::text[], array['Verdesse'], '2018-11-21'),
  ('Bianca Remungia', 834, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Blatterle', 835, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Codronisca', 836, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Cranaccia Arussa', 837, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Cuccuau', 838, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Fiudedda', 839, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Cabernet Eidos', 840, 'nera', array[]::text[], array['Ud-58.083'], '2015-08-04'),
  ('Cabernet Volos', 841, 'nera', array[]::text[], array['Ud-32.078'], '2015-08-04'),
  ('Merlot Kanthus', 842, 'nera', array[]::text[], array['Ud-31.122'], '2015-08-04'),
  ('Merlot Khorus', 843, 'nera', array[]::text[], array['Ud-31.125'], '2015-08-04'),
  ('Sauvignon Kretos', 844, 'bianca', array[]::text[], array['Ud-76.026'], '2015-08-04'),
  ('Sauvignon Nepis', 845, 'bianca', array[]::text[], array['Ud-55.098'], '2015-08-04'),
  ('Sauvignon Rytos', 846, 'bianca', array[]::text[], array['Ud-55.100'], '2015-08-04'),
  ('Grand Noir', 847, 'nera', array[]::text[], array[]::text[], '2015-12-30'),
  ('Mourvedre', 848, 'nera', array[]::text[], array['Monastrell'], '2015-12-30'),
  ('Albana Rosa', 849, 'rosa', array[]::text[], array[]::text[], '2016-06-08'),
  ('Festasio', 850, 'nera', array[]::text[], array[]::text[], '2016-06-08'),
  ('Lambrusco del Pellegrino', 851, 'nera', array[]::text[], array[]::text[], '2016-06-08'),
  ('Merera', 852, 'nera', array[]::text[], array[]::text[], '2016-06-08'),
  ('Passeretta', 853, 'bianca', array[]::text[], array[]::text[], '2016-06-08'),
  ('Morellone', 854, 'nera', array[]::text[], array[]::text[], '2016-12-28'),
  ('Negrone', 855, 'nera', array[]::text[], array[]::text[], '2016-12-28'),
  ('Malvasia Casalini', 856, 'bianca', array[]::text[], array[]::text[], '2017-10-05'),
  ('Moscato d Amburgo', 857, 'nera', array[]::text[], array[]::text[], '2017-10-05'),
  ('Nocchianello Bianco', 858, 'bianca', array[]::text[], array[]::text[], '2017-10-05'),
  ('Nocchianello Nero', 859, 'nera', array[]::text[], array[]::text[], '2017-10-05'),
  ('Tintoria', 860, 'nera', array[]::text[], array[]::text[], '2018-05-30'),
  ('Fraueler', 861, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Furner', 862, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Gralima', 863, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Gregu Nieddu', 864, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Inzolia Nera', 865, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Licronaxu', 866, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Liseiret', 867, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Lucignola', 868, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Mara Bianca', 869, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Medrulinu', 870, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Nera del Ponte', 871, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Niedda Carta', 872, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Orisi', 873, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Recunu', 874, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Saluda e Passa', 875, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Selezione Vedele', 876, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Usirioto', 877, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Versoalen', 878, 'bianca', array[]::text[], array[]::text[], '2018-11-21'),
  ('Vitrarolo', 879, 'nera', array[]::text[], array[]::text[], '2018-11-21'),
  ('Aniga Bragia', 880, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Bianca Addosa', 881, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Colatamurro', 882, 'nera', array[]::text[], array[]::text[], '2019-05-23'),
  ('Doronadu', 883, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Elmo', 884, 'nera', array[]::text[], array[]::text[], '2019-05-23'),
  ('Furcina', 885, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Giosana', 886, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Licronaxu Rosa', 887, 'rosa', array[]::text[], array[]::text[], '2019-05-23'),
  ('Moscianello', 889, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Nigheddu Polchinu', 890, 'nera', array[]::text[], array[]::text[], '2019-05-23'),
  ('Nuragus Arrubiu', 891, 'rosa', array[]::text[], array[]::text[], '2019-05-23'),
  ('Pansale', 892, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Plavina', 893, 'nera', array[]::text[], array[]::text[], '2019-05-23'),
  ('Poloskei Muskotaly', 894, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Procu Nieddu', 895, 'nera', array[]::text[], array[]::text[], '2019-05-23'),
  ('Rondinella', 896, 'rosa', array[]::text[], array[]::text[], '2019-05-23'),
  ('Rosonadu', 897, 'rosa', array[]::text[], array[]::text[], '2019-05-23'),
  ('Santa Sofia', 898, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Schioppetta', 899, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Sgranarella', 900, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Sinnidanu', 901, 'bianca', array[]::text[], array[]::text[], '2019-05-23'),
  ('Cigliola Bianca', 902, 'bianca', array[]::text[], array['Uva Attina'], '2020-01-07'),
  ('Santa Teresa', 903, 'bianca', array[]::text[], array[]::text[], '2020-01-07'),
  ('Biondello', 904, 'bianca', array[]::text[], array[]::text[], '2020-06-09'),
  ('Carrieri', 905, 'bianca', array[]::text[], array[]::text[], '2020-06-09'),
  ('Brettio Nero', 906, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Kersus', 907, 'bianca', array[]::text[], array[]::text[], '2020-06-09'),
  ('Pinot Iskra', 908, 'bianca', array[]::text[], array[]::text[], '2020-06-09'),
  ('Volturnis', 909, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Pinot Kors', 910, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Pinot Regina', 911, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Maturano Nero', 912, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Uva Giulia', 913, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Recaldina', 914, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Pecolo Scuro', 915, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Cabernet Blanc', 916, 'bianca', array[]::text[], array[]::text[], '2020-06-09'),
  ('Cabertin', 917, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Pinotin', 918, 'nera', array[]::text[], array[]::text[], '2020-06-09'),
  ('Termantis', 919, 'nera', array[]::text[], array['F22p09'], '2020-06-09'),
  ('Nermantis', 920, 'nera', array[]::text[], array['F22p10'], '2020-06-09'),
  ('Charvir', 921, 'bianca', array[]::text[], array['F23p65'], '2020-06-09'),
  ('Valnosia', 922, 'bianca', array[]::text[], array['F26p92'], '2020-06-09'),
  ('Grecarese', 923, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Lagario', 924, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Moretto Grosso', 925, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Negrellone', 926, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Palma', 927, 'bianca', array[]::text[], array[]::text[], '2021-02-10'),
  ('Ranchella', 928, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Raspato Nero', 929, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Reale Bianca', 930, 'bianca', array[]::text[], array[]::text[], '2021-02-10'),
  ('Sevar', 931, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Sorantonio', 932, 'nera', array[]::text[], array[]::text[], '2021-02-10'),
  ('Perla di Csaba', 933, 'bianca', array[]::text[], array[]::text[], '2021-02-10'),
  ('Magliocco Dolce', 934, 'nera', array[]::text[], array['Marsigliana', 'Greco Nero', 'Arvino.'], '2019-05-23'),
  ('Benedina', 936, 'nera', array[]::text[], array[]::text[], '2021-07-01'),
  ('Bigolona', 937, 'bianca', array[]::text[], array[]::text[], '2021-07-01'),
  ('Camaiola', 938, 'nera', array[]::text[], array[]::text[], '2021-07-01'),
  ('Mattarella', 939, 'bianca', array[]::text[], array[]::text[], '2021-07-01'),
  ('Rabosa Bianca', 940, 'bianca', array[]::text[], array[]::text[], '2021-07-01'),
  ('Ghiandara', 941, 'bianca', array[]::text[], array['Ghiannara'], '2022-02-25'),
  ('Gnoca', 942, 'nera', array[]::text[], array[]::text[], '2022-02-25'),
  ('Zimellone Bianco', 943, 'bianca', array[]::text[], array['Sirocchia'], '2022-02-25'),
  ('Cavecia', 951, 'bianca', array[]::text[], array[]::text[], '2022-05-17'),
  ('Russiola', 952, 'nera', array[]::text[], array[]::text[], '2022-05-17'),
  ('Coda di Pecora', 954, 'bianca', array[]::text[], array[]::text[], '2023-03-03'),
  ('Rossella', 955, null, array[]::text[], array[]::text[], '2023-03-03'),
  ('Roussi', 956, null, array[]::text[], array[]::text[], '2023-03-03'),
  ('Alfrocheiro', 967, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Arinto', 968, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Assyrtiko', 969, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Bastardo', 970, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Castelao', 971, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Fernao Pires', 972, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Godello', 973, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Loureiro', 974, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Macabeo', 975, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Moschomavro', 976, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Pattaresca', 977, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Touriga Nacional', 978, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Viosinho', 979, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Xinomavro', 980, null, array[]::text[], array[]::text[], '2023-05-03'),
  ('Agostina', 985, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Castagnara', 986, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Cassina', 987, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Ingannapastore', 988, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Sabato', 989, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Suppezza', 990, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Tennecchia', 991, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Uva Urmo', 992, null, array[]::text[], array[]::text[], '2023-06-26'),
  ('Nero Antico', 994, null, array[]::text[], array[]::text[], '2023-10-26'),
  ('Cocozza', 995, null, array[]::text[], array[]::text[], '2023-10-26'),
  ('Reginella', 996, null, array[]::text[], array[]::text[], '2023-10-26'),
  ('Racina Piccola', 997, null, array[]::text[], array[]::text[], '2023-10-26'),
  ('Vodorin', 998, null, array[]::text[], array[]::text[], '2023-10-26')
on conflict (rnv_number) do nothing;
