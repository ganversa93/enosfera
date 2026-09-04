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
