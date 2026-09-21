// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: enrich-winery-catalog
//
// Completa il campo "vitigno" dei vini di catalogo di una cantina che
// ne sono ancora privi (importati solo con nome+link da
// import-winery-catalog, deliberatamente senza AI, vedi quel file):
// legge la pagina prodotto di ciascuno e chiede a Claude, in UNA sola
// chiamata per tutta la cantina invece che una a vino, di estrarre il
// vitigno di ognuno — molto più veloce ed economico, restando comunque
// testo puro (nessuna immagine, stesso discorso costi di
// enrich-winery-profile).
//
// Solo admin, come enrich-winery-profile — ma a differenza di quella,
// QUESTA scrive direttamente su winery_wines.grapes: qui non c'è un
// form da rivedere riga per riga come per la scheda cantina, e il
// valore resta comunque modificabile in un secondo momento con
// "Modifica" sul catalogo se l'estrazione fosse imprecisa.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const FETCH_TIMEOUT_MS = 15000;
const MAX_HTML_BYTES = 800_000;
// Per vino, molto più corto che in enrich-winery-profile: qui se ne
// inviano insieme fino a MAX_WINES, il totale deve restare ragionevole.
const MAX_TEXT_CHARS_PER_WINE = 1500;
const MAX_WINES = 25;

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
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; EnoscrignoEnricher/1.0)' },
    });
  } finally {
    clearTimeout(t);
  }
}

function htmlToCleanText(html: string, maxChars: number): string {
  const text = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<nav[\s\S]*?<\/nav>/gi, ' ')
    .replace(/<footer[\s\S]*?<\/footer>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&').replace(/&nbsp;/g, ' ').replace(/&quot;/g, '"').replace(/&#039;/g, "'")
    .replace(/&#8217;/g, '’').replace(/&#8216;/g, '‘').replace(/&#8220;/g, '“').replace(/&#8221;/g, '”').replace(/&#8211;/g, '–')
    .replace(/\s+/g, ' ')
    .trim();
  return text.slice(0, maxChars);
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
    const wineryId = typeof body?.wineryId === 'string' ? body.wineryId : '';
    if (!wineryId) return json({ error: 'bad_request', message: 'wineryId mancante' }, 200);

    const { data: allWines, error: winesErr } = await sbAdmin
      .from('winery_wines')
      .select('id,name,grapes,link')
      .eq('winery_id', wineryId);
    if (winesErr) return json({ error: 'server_error', message: 'Errore lettura catalogo: ' + winesErr.message }, 200);

    const wines = (allWines || []).filter((w) => w.link && !w.grapes).slice(0, MAX_WINES);
    if (!wines.length) {
      return json({ ok: true, checked: 0, updated: 0, failed: 0, message: 'Nessun vino senza vitigno da completare.' });
    }

    // Legge le pagine prodotto in parallelo — i fallimenti (sito lento,
    // pagina spostata) vengono semplicemente scartati, non bloccano gli
    // altri vini della stessa cantina.
    const pages = await Promise.all(wines.map(async (w) => {
      try {
        const resp = await fetchWithTimeout(w.link);
        if (!resp.ok) return null;
        const html = (await resp.text()).slice(0, MAX_HTML_BYTES);
        const text = htmlToCleanText(html, MAX_TEXT_CHARS_PER_WINE);
        return text ? { id: w.id as string, name: w.name as string, text } : null;
      } catch {
        return null;
      }
    }));
    const readable = pages.filter((p) => p !== null) as { id: string; name: string; text: string }[];
    const failedCount = wines.length - readable.length;
    if (!readable.length) {
      return json({ ok: true, checked: wines.length, updated: 0, failed: failedCount, message: 'Nessuna pagina prodotto raggiungibile.' });
    }

    const promptText = `Per ciascuno dei seguenti vini, estrai il vitigno/uvaggio dal testo della sua pagina prodotto. Rispondi SOLO con un array JSON valido, zero testo extra, zero markdown, nello schema [{"id":"","grapes":""}]. Un elemento per ogni vino della lista, stesso "id" indicato. "grapes" è il vitigno o l'uvaggio (es. "Corvina 60%, Rondinella 20%, Molinara 20%" oppure solo "Sangiovese" se in purezza) — stringa vuota se non è indicato chiaramente nel testo, non indovinare.\n\n${readable.map((w, i) => `${i + 1}) id: ${w.id} — "${w.name}"\n${w.text}`).join('\n\n')}`;

    const aiResp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 2000,
        messages: [{ role: 'user', content: promptText }],
      }),
    });

    if (!aiResp.ok) {
      const errText = await aiResp.text();
      console.error('Anthropic API error:', aiResp.status, errText);
      return json({ error: 'ai_error', message: 'Errore nella lettura dei vini. Riprova più tardi.' }, 200);
    }

    const aiData = await aiResp.json();
    const responseText = (aiData.content || []).map((b: any) => b.text || '').join('');
    let extracted: { id: string; grapes: string }[];
    try {
      extracted = JSON.parse(responseText.replace(/```json|```/g, '').trim());
    } catch {
      return json({ error: 'parse_error', message: 'Non sono riuscito a interpretare la risposta. Riprova più tardi.' }, 200);
    }

    let updated = 0;
    for (const item of extracted) {
      if (!item?.id || !item?.grapes) continue;
      const { error: updErr } = await sbAdmin.from('winery_wines').update({ grapes: item.grapes }).eq('id', item.id);
      if (!updErr) updated++;
    }

    return json({ ok: true, checked: wines.length, updated, failed: failedCount });
  } catch (err) {
    console.error('enrich-winery-catalog error:', err);
    return json({ error: 'server_error', message: `Errore imprevisto: ${err instanceof Error ? err.message : String(err)}` }, 200);
  }
});
