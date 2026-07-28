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

-- ════════════════════════════════════════════
-- AIS — scheda analitico-descrittiva (in aggiunta a quella a punteggio,
-- che l'AIS compila sempre entrambe: niente toggle, i due schemi
-- convivono nello stesso record sotto deg_schema = 'ais')
-- ════════════════════════════════════════════
alter table public.wines add column if not exists ais_desc_params jsonb;
