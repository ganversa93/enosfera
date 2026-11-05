// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: aggregate-events
//
// Letta una lista di pagine "fonte" (config_lists, list_key
// 'event_source_url' — l'admin la gestisce da Configurazione liste,
// stesso meccanismo già usato per event_category/event_association),
// legge ciascuna pagina e usa l'API Anthropic (stessa chiave di
// scan-label/enrich-winery-profile) per estrarne eventi enologici
// strutturati. A differenza di enrich-winery-profile, QUI la funzione
// scrive direttamente su public.events — ma sempre con status
// 'pending', mai 'approved': finisce nella stessa coda di revisione
// già usata per gli eventi inseriti dalle cantine (vedi "Eventi in
// attesa di approvazione" in index.html), così l'aggregazione resta
// un suggerimento che un admin vaglia a mano, non una pubblicazione
// automatica.
//
// Solo admin, innescata a mano da un bottone (nessun cron): i volumi
// sono bassi e l'admin decide quando vale la pena spendere qualche
// chiamata AI, esattamente come enrich-winery-profile.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function notifyAdminError(fn: string, err: unknown) {
  try {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Enoscrigno <noreply@enoscrigno.it>',
        to: ['enoscrigno@gmail.com'],
        subject: `Errore in ${fn} — Enoscrigno`,
        html: `<p style="font-family:Arial,sans-serif">Errore imprevisto nella Edge Function <b>${fn}</b>:</p><pre style="white-space:pre-wrap;font-size:12px;background:#f5f5f5;padding:12px;border-radius:8px">${String(err instanceof Error ? err.stack || err.message : err).slice(0, 2000)}</pre>`,
      }),
    });
  } catch {}
}

const FETCH_TIMEOUT_MS = 15000;
const MAX_HTML_BYTES = 2_000_000;
const MAX_TEXT_CHARS = 10000;
// Tenuto basso: ogni fonte è di solito una pagina "indice eventi" di
// un'associazione/ente, non serve scansionarne decine per ogni run —
// l'admin può rilanciare quando vuole.
const MAX_SOURCES = 8;
const MAX_EVENTS_PER_SOURCE = 15;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

async function fetchWithTimeout(url: string) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, {
      signal: controller.signal,
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; EnoscrignoEventAggregator/1.0)' },
    });
  } finally {
    clearTimeout(t);
  }
}

// baseUrl risolve gli href relativi ("/eventi/123") in URL assoluti: senza
// non avrebbe senso scriverli nel testo, l'AI non potrebbe mai riusarli
// come "website" di un evento.
function htmlToCleanText(html: string, baseUrl?: string): string {
  // I link vanno preservati PRIMA di buttare via il resto del markup,
  // altrimenti l'AI non vede mai nessun URL e "website" resta sempre
  // vuoto (il bug segnalato dall'utente): ogni <a href> diventa
  // "testo del link (URL assoluto)" dentro il testo pulito.
  const withLinks = html.replace(/<a\s+[^>]*href=["']([^"'#][^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi, (_m, href, inner) => {
    let abs = href;
    if (baseUrl) {
      try { abs = new URL(href, baseUrl).toString(); } catch {}
    }
    const label = inner.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    return label ? ` ${label} (${abs}) ` : ` (${abs}) `;
  });
  const text = withLinks
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<nav[\s\S]*?<\/nav>/gi, ' ')
    .replace(/<footer[\s\S]*?<\/footer>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&').replace(/&nbsp;/g, ' ').replace(/&quot;/g, '"').replace(/&#039;/g, "'")
    .replace(/&#8217;/g, '’').replace(/&#8216;/g, '‘').replace(/&#8220;/g, '“').replace(/&#8221;/g, '”').replace(/&#8211;/g, '–')
    .replace(/\s+/g, ' ')
    .trim();
  return text.slice(0, MAX_TEXT_CHARS);
}

function hostnameOf(url: string): string {
  try { return new URL(url).hostname.replace(/^www\./, ''); } catch { return url; }
}

interface ExtractedEvent {
  name: string;
  category: string;
  date_from: string;
  date_to: string;
  region: string;
  province: string;
  location_name: string;
  address: string;
  website: string;
  description: string;
}

async function extractEventsFromText(text: string, sourceUrl: string, categoryOptions: string[], todayIso: string): Promise<ExtractedEvent[]> {
  const promptText = `Ecco il testo di una pagina che elenca eventi enologici (degustazioni, cantine aperte, fiere del vino, corsi/masterclass). La pagina è: ${sourceUrl}\n\nNel testo, ogni link originale è stato riscritto nella forma "testo del link (URL)" subito dopo il testo visibile — usa questi URL per il campo "website", scegliendo quello il cui testo/contesto riguarda chiaramente QUELL'evento specifico (es. "Programma e prenotazioni", "Scopri di più", il titolo dell'evento stesso), non un link generico di navigazione, social o la pagina indice da cui provengono tutti gli eventi.\n\nEstrai SOLO gli eventi enologici reali con una data chiara, futura o in corso rispetto a oggi (${todayIso}) — ignora eventi passati, voci di menu, link generici o contenuti non pertinenti al vino. Rispondi SOLO con un array JSON valido, zero testo extra, zero markdown, massimo ${MAX_EVENTS_PER_SOURCE} elementi. Schema di ogni elemento: {"name":"","category":"","date_from":"","date_to":"","region":"","province":"","location_name":"","address":"","website":"","description":""}.\n"name" è il titolo dell'evento, obbligatorio.\n"category" deve essere ESATTAMENTE uno tra questi valori se uno corrisponde chiaramente, altrimenti stringa vuota (non indovinare): ${categoryOptions.join(', ') || '(nessuna categoria configurata)'}.\n"date_from"/"date_to" in formato ISO yyyy-mm-dd; "date_to" vuoto se l'evento dura un solo giorno o la data di fine non è chiara.\n"region"/"province" solo se il testo le rende chiare (per l'Italia, sigla o nome provincia, es. "Verona"); altrimenti stringa vuota.\n"website" è l'URL (tra parentesi nel testo, vedi sopra) del link specifico a QUESTO evento, se presente, altrimenti stringa vuota — non inventare mai un URL che non compare nel testo.\n"description" è 1-2 frasi in italiano basate SOLO su quanto scritto nel testo, senza inventare dettagli.\nSe non trovi nessun evento valido, rispondi con un array vuoto [].\n\nTesto della pagina:\n${text}`;

  const aiResp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 3000,
      messages: [{ role: 'user', content: promptText }],
    }),
  });

  if (!aiResp.ok) {
    const errText = await aiResp.text();
    console.error('Anthropic API error:', aiResp.status, errText);
    throw new Error(`Errore AI (${aiResp.status})`);
  }

  const aiData = await aiResp.json();
  const responseText = (aiData.content || []).map((b: any) => b.text || '').join('');
  let extracted: unknown;
  try {
    extracted = JSON.parse(responseText.replace(/```json|```/g, '').trim());
  } catch {
    throw new Error('Risposta AI non interpretabile');
  }
  if (!Array.isArray(extracted)) return [];
  return extracted.filter((e: any) => e && typeof e.name === 'string' && e.name.trim()) as ExtractedEvent[];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) return json({ error: 'auth', message: 'Devi essere autenticato' }, 200);

    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: userData, error: userErr } = await sbAdmin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: 'auth', message: 'Sessione non valida' }, 200);

    const { data: profile } = await sbAdmin.from('profiles').select('is_admin').eq('id', userData.user.id).maybeSingle();
    if (!profile?.is_admin) return json({ error: 'forbidden', message: 'Solo un admin può usare questa funzione' }, 200);

    const body = await req.json().catch(() => ({}));

    // Modalità test (bottone "Testa" accanto a una fonte in Configurazione
    // liste): verifica solo che l'URL risponda e contenga testo leggibile,
    // nessuna chiamata AI — serve a scoprire subito una fonte morta/bloccata
    // (es. anti-bot) invece che solo durante un'aggregazione vera, dove
    // avrebbe già speso chiamate AI sulle altre fonti buone.
    const testUrl = typeof body?.test_url === 'string' ? body.test_url.trim() : '';
    if (testUrl) {
      let parsedTest: URL;
      try { parsedTest = new URL(testUrl); } catch { return json({ error: 'bad_request', message: 'URL non valido' }, 200); }
      if (parsedTest.protocol !== 'http:' && parsedTest.protocol !== 'https:') return json({ error: 'bad_request', message: 'URL non valido' }, 200);
      try {
        const pageResp = await fetchWithTimeout(parsedTest.toString());
        if (!pageResp.ok) return json({ error: 'fetch_error', message: `Il sito risponde con un errore (HTTP ${pageResp.status}) — probabilmente blocca le richieste automatiche.` }, 200);
        const html = (await pageResp.text()).slice(0, MAX_HTML_BYTES);
        const text = htmlToCleanText(html, parsedTest.toString());
        if (!text || text.length < 100) return json({ error: 'empty_page', message: 'La pagina risponde ma non contiene testo leggibile a sufficienza.' }, 200);
        return json({ data: { ok: true, text_length: text.length, preview: text.slice(0, 200) } });
      } catch (testErr) {
        const reason = testErr instanceof Error && testErr.name === 'AbortError' ? 'Il sito ha impiegato troppo tempo a rispondere (timeout).' : `Impossibile raggiungere il sito: ${testErr instanceof Error ? testErr.message : String(testErr)}`;
        return json({ error: 'fetch_error', message: reason }, 200);
      }
    }

    const { data: sourceRows } = await sbAdmin.from('config_lists').select('value').eq('list_key', 'event_source_url').order('sort_order');
    const sources = (sourceRows || []).map(r => r.value).filter(Boolean).slice(0, MAX_SOURCES);
    if (!sources.length) {
      return json({ error: 'no_sources', message: 'Nessuna fonte configurata: aggiungine da Configurazione liste → Fonti aggregazione eventi.' }, 200);
    }

    const { data: catRows } = await sbAdmin.from('config_lists').select('value').eq('list_key', 'event_category').order('sort_order');
    const categoryOptions = (catRows || []).map(r => r.value).filter(Boolean);

    const { data: existingRows } = await sbAdmin.from('events').select('name,date_from,source_url');
    const existingBySourceKey = new Set((existingRows || []).map(e => `${e.source_url || ''}|${(e.name || '').trim().toLowerCase()}|${e.date_from || ''}`));
    const existingByNameDate = new Set((existingRows || []).map(e => `${(e.name || '').trim().toLowerCase()}|${e.date_from || ''}`));

    const todayIso = new Date().toISOString().slice(0, 10);
    let inserted = 0;
    let skippedDuplicate = 0;
    let skippedPast = 0;
    const sourcesFailed: { url: string; reason: string }[] = [];

    for (const sourceUrl of sources) {
      let parsed: URL;
      try { parsed = new URL(sourceUrl); } catch { sourcesFailed.push({ url: sourceUrl, reason: 'URL non valido' }); continue; }
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') { sourcesFailed.push({ url: sourceUrl, reason: 'URL non valido' }); continue; }

      try {
        const pageResp = await fetchWithTimeout(parsed.toString());
        if (!pageResp.ok) { sourcesFailed.push({ url: sourceUrl, reason: `HTTP ${pageResp.status}` }); continue; }
        const html = (await pageResp.text()).slice(0, MAX_HTML_BYTES);
        const text = htmlToCleanText(html, parsed.toString());
        if (!text) { sourcesFailed.push({ url: sourceUrl, reason: 'Pagina vuota o illeggibile' }); continue; }

        const events = await extractEventsFromText(text, sourceUrl, categoryOptions, todayIso);
        const source = hostnameOf(sourceUrl);

        for (const e of events) {
          const name = e.name.trim();
          if (!name) continue;
          const dateFrom = /^\d{4}-\d{2}-\d{2}$/.test(e.date_from || '') ? e.date_from : null;
          if (dateFrom && dateFrom < todayIso) { skippedPast++; continue; }
          const sourceKey = `${sourceUrl}|${name.toLowerCase()}|${dateFrom || ''}`;
          const nameDateKey = `${name.toLowerCase()}|${dateFrom || ''}`;
          if (existingBySourceKey.has(sourceKey) || existingByNameDate.has(nameDateKey)) { skippedDuplicate++; continue; }

          const category = categoryOptions.includes(e.category) ? e.category : null;
          const { error: insErr } = await sbAdmin.from('events').insert({
            name,
            category,
            date_from: dateFrom,
            date_to: /^\d{4}-\d{2}-\d{2}$/.test(e.date_to || '') ? e.date_to : null,
            region: e.region?.trim() || null,
            province: e.province?.trim() || null,
            location_name: e.location_name?.trim() || null,
            address: e.address?.trim() || null,
            website: e.website?.trim() || null,
            description: e.description?.trim() || null,
            source,
            source_url: sourceUrl,
            status: 'pending',
            created_by: userData.user.id,
          });
          if (insErr) { console.error('insert event error:', insErr); continue; }
          existingBySourceKey.add(sourceKey);
          existingByNameDate.add(nameDateKey);
          inserted++;
        }
      } catch (sourceErr) {
        const reason = sourceErr instanceof Error && sourceErr.name === 'AbortError' ? 'Timeout' : (sourceErr instanceof Error ? sourceErr.message : String(sourceErr));
        sourcesFailed.push({ url: sourceUrl, reason });
      }
    }

    return json({ data: { inserted, skipped_duplicate: skippedDuplicate, skipped_past: skippedPast, sources_scanned: sources.length, sources_failed: sourcesFailed } });
  } catch (err) {
    console.error('aggregate-events error:', err);
    await notifyAdminError('aggregate-events', err);
    return json({ error: 'server_error', message: `Errore imprevisto: ${err instanceof Error ? err.message : String(err)}` }, 200);
  }
});
