// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: enrich-winery-profile
//
// Dato il sito web di una cantina, ne legge la homepage e usa l'API
// Anthropic (stessa chiave già usata da scan-label) per proporre
// Paese/Regione/Provincia/Descrizione da precompilare nella scheda
// cantina — l'admin rivede e salva come sempre con "Salva scheda"
// (saveWineryDetails() in index.html): questa funzione non scrive
// mai sul database, restituisce solo dati da rivedere.
//
// Solo admin (a differenza di import-winery-catalog, che ammette
// anche il proprietario collegato della cantina): è uno strumento
// per popolare l'anagrafica di cantine ancora senza scheda, non una
// funzione self-service — vedi loadWineriesToComplete() in index.html
// per l'elenco che l'admin sta smaltendo.
//
// Nessun limite di utilizzo tipo scan_usage (PER_USER_MONTHLY_LIMIT/
// GLOBAL_MONTHLY_LIMIT su scan-label): qui l'uso è solo admin, volumi
// bassissimi (poche decine/centinaia di chiamate in tutto, mai per
// utente finale), e il costo per chiamata è già trascurabile — è
// testo, non immagini, quindi molto più economico di uno scan
// etichetta pur usando lo stesso modello.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const FETCH_TIMEOUT_MS = 10000;
const MAX_HTML_BYTES = 1_500_000;
// Testo ripulito inviato all'AI: tenuto corto di proposito — è la parte di
// "ottimizzazione del recupero informazioni" che tiene il costo per
// chiamata a poche frazioni di centesimo invece di qualche centesimo.
const MAX_TEXT_CHARS = 6000;

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

// Ripulisce l'HTML a solo testo leggibile, scartando script/style/nav/
// footer — sono la parte che pesa di più in token senza portare
// informazione utile all'estrazione (menu, cookie banner, link social…).
function htmlToCleanText(html: string): string {
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
  return text.slice(0, MAX_TEXT_CHARS);
}

const COUNTRY_OPTIONS = ['Italia', 'Francia', 'Germania', 'Spagna', 'Stati Uniti', 'Cile', 'Argentina', 'Nuova Zelanda', 'Sud Africa', 'Australia', 'Altro'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) return json({ error: 'Devi essere autenticato' }, 401);

    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: userData, error: userErr } = await sbAdmin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: 'Sessione non valida' }, 401);

    const { data: profile } = await sbAdmin.from('profiles').select('is_admin').eq('id', userData.user.id).maybeSingle();
    if (!profile?.is_admin) return json({ error: 'Solo un admin può usare questa funzione' }, 403);

    const body = await req.json().catch(() => ({}));
    const website = typeof body?.website === 'string' ? body.website.trim() : '';
    if (!website) return json({ error: 'Sito web mancante' }, 400);

    let parsed: URL;
    try { parsed = new URL(website); } catch { return json({ error: 'Link non valido' }, 400); }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return json({ error: 'Link non valido' }, 400);

    const pageResp = await fetchWithTimeout(parsed.toString());
    if (!pageResp.ok) return json({ error: `Impossibile raggiungere il sito (${pageResp.status})` }, 502);
    const html = (await pageResp.text()).slice(0, MAX_HTML_BYTES);
    const text = htmlToCleanText(html);
    if (!text) return json({ error: 'Pagina vuota o illeggibile' }, 502);

    const promptText = `Ecco il testo della homepage del sito di una cantina vinicola. Estrai le informazioni richieste. Rispondi SOLO con JSON valido, zero testo extra, zero markdown. Schema: {"country":"","region":"","province":"","description":""}. "country" deve essere ESATTAMENTE uno tra questi valori (scegli il più adatto, "Altro" se nessuno corrisponde, stringa vuota se non è per niente chiaro): ${COUNTRY_OPTIONS.join(', ')}. "region" e "province" solo se il testo le rende chiare (per un'azienda italiana, la provincia è quella della sede/cantina, es. "Verona"); altrimenti stringa vuota — non indovinare. "description" è una breve descrizione in italiano (2-3 frasi) della cantina basata SOLO su quanto scritto nel testo, in terza persona, senza inventare dettagli non presenti.\n\nTesto della pagina:\n${text}`;

    const aiResp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 500,
        messages: [{ role: 'user', content: promptText }],
      }),
    });

    if (!aiResp.ok) {
      const errText = await aiResp.text();
      console.error('Anthropic API error:', aiResp.status, errText);
      return json({ error: 'ai_error', message: 'Errore nella lettura del sito. Riprova o compila a mano.' }, 502);
    }

    const aiData = await aiResp.json();
    const responseText = (aiData.content || []).map((b: any) => b.text || '').join('');
    let extracted;
    try {
      extracted = JSON.parse(responseText.replace(/```json|```/g, '').trim());
    } catch {
      return json({ error: 'parse_error', message: 'Non sono riuscito a interpretare il sito. Riprova o compila a mano.' }, 502);
    }

    return json({ data: extracted });
  } catch (err) {
    console.error('enrich-winery-profile error:', err);
    return json({ error: 'server_error', message: 'Errore imprevisto. Riprova più tardi.' }, 500);
  }
});
