// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: import-winery-catalog
//
// Popola in blocco la base del catalogo vini di una cantina (solo
// nome + link alla scheda prodotto) leggendo la pagina negozio/vini
// del sito del produttore, invece di inserirli uno a uno a mano.
// Deliberatamente minimale: niente uvaggio, niente estrazione via AI —
// solo un punto di partenza che l'admin rifinisce dopo con la modifica
// già presente sul catalogo (vedi editWineryCatalogWine in index.html).
//
// Funziona bene con negozi WooCommerce (il caso più comune tra i
// piccoli produttori italiani); con temi molto diversi potrebbe non
// trovare nulla — in tal caso resta comunque possibile aggiungere i
// vini a mano dalla scheda cantina.
//
// Accetta sia il link a una pagina elenco (prova a estrarre più vini
// insieme) sia il link alla scheda di un singolo vino (in quel caso
// aggiunge solo quello, prendendone il nome dall'<h1> della pagina).
//
// Se lo scraping a regex non trova nulla (siti con markup diverso da
// WooCommerce, la maggioranza nella pratica), prima di arrendersi si
// tenta un fallback via Claude (stessa ANTHROPIC_API_KEY già in uso in
// scan-label/enrich-winery-*): si estraggono tutti i link della pagina
// come "testo — url" (vedi extractLinksAsText) e si chiede all'AI di
// scegliere quali sono davvero pagine prodotto di un vino — un compito
// che la regex fa con un elenco fisso di NAV_WORDS e non generalizza a
// siti diversi da quello per cui è tarata.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

const FETCH_TIMEOUT_MS = 10000;
const MAX_HTML_BYTES = 3_000_000;
const MAX_PRODUCTS = 60;

async function fetchWithTimeout(url: string) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, {
      signal: controller.signal,
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; EnoscrignoImporter/1.0)' },
    });
  } finally {
    clearTimeout(t);
  }
}

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, '&').replace(/&#8217;/g, '’').replace(/&#8216;/g, '‘')
    .replace(/&#8220;/g, '“').replace(/&#8221;/g, '”').replace(/&#8211;/g, '–')
    .replace(/&quot;/g, '"').replace(/&#039;/g, "'").replace(/&nbsp;/g, ' ')
    .trim();
}

function stripTags(html: string): string {
  return html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

// Filtro minimo per scartare voci di menu/nav catturate per sbaglio dal
// pattern 3 (link generico), che non ha nessun ancoraggio semantico oltre
// al percorso dell'URL — inclusi i selettori di lingua ("ITA", "ENG"),
// sigle corte tutte maiuscole senza spazi, molto improbabili come nome
// di un vino.
const NAV_WORDS = ['home', 'contatt', 'chi siamo', 'cookie', 'privacy', 'menu', 'carrello', 'accedi', 'login', 'cerca', 'blog', 'news', 'faq', 'newsletter'];
function looksLikeProductName(name: string): boolean {
  if (!name || name.length < 2 || name.length > 70) return false;
  if (!/[a-zA-ZÀ-ÿ]/.test(name)) return false;
  if (name.length <= 4 && !/\s/.test(name) && name === name.toUpperCase()) return false;
  const lower = name.toLowerCase();
  return !NAV_WORDS.some(w => lower === w || lower.includes(w));
}

function extractH1(html: string): string | null {
  const m = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
  if (!m) return null;
  const text = decodeEntities(stripTags(m[1]));
  return text || null;
}

// Una singola pagina prodotto (es. /prodotti/nome-vino, senza altri
// segmenti dopo lo slug) va trattata diversamente da una pagina elenco:
// cercarci dentro pattern da griglia prodotti raccoglie solo link della
// navigazione della pagina stessa (selettore lingua, correlati…), non il
// vino in questione. In questo caso il nome giusto è quello della pagina.
function isSingleProductPath(pathname: string): boolean {
  return /^\/(?:vini?|prodott[oi]|products?|shop|negozio|wines?)\/[^/]+\/?$/i.test(pathname);
}

function collect(re: RegExp, html: string, baseUrl: string, seen: Map<string, string>, getName: (m: RegExpExecArray) => string) {
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) && seen.size < MAX_PRODUCTS) {
    let link: string;
    try { link = new URL(m[1], baseUrl).toString(); } catch { continue; }
    const name = getName(m);
    if (looksLikeProductName(name) && !seen.has(link)) seen.set(link, name);
  }
}

// Tre livelli, dal più preciso al più generico — si passa al successivo
// solo se il precedente non ha trovato nulla:
// 1) WooCommerce: <a href>...<h2/h3 class="...product...title...">Nome</h2>
// 2) Titolo generico (h2/h3) subito dopo il link, per temi non WooCommerce
//    che comunque strutturano la griglia prodotti allo stesso modo.
// 3) Ultima spiaggia per siti costruiti a mano/non e-commerce: link il cui
//    percorso somiglia a una scheda vino/prodotto, usando il testo del
//    link stesso come nome.
function extractProducts(html: string, baseUrl: string): { name: string; link: string }[] {
  const seen = new Map<string, string>();

  collect(
    /<a[^>]+href="([^"]+)"[^>]*>[\s\S]{0,500}?<h[23][^>]*class="[^"]*product[^"]*title[^"]*"[^>]*>([^<]+)<\/h[23]>/gi,
    html, baseUrl, seen, m => decodeEntities(m[2])
  );

  if (!seen.size) {
    collect(
      /<a[^>]+href="([^"]+)"[^>]*>\s*<h[23][^>]*>([^<]+)<\/h[23]>/gi,
      html, baseUrl, seen, m => decodeEntities(m[2])
    );
  }

  if (!seen.size) {
    collect(
      /<a[^>]+href="([^"]*\/(?:vini?|prodott[oi]|products?|shop|negozio|wines?)\/[^"?#]+)"[^>]*>([\s\S]{0,200}?)<\/a>/gi,
      html, baseUrl, seen, m => decodeEntities(stripTags(m[2]))
    );
  }

  return [...seen.entries()].map(([link, name]) => ({ name, link }));
}

const MAX_LINKS_FOR_AI = 300;
const MAX_LINKS_TEXT_CHARS = 8000;

// Scarta script/style/nav/footer poi riduce ogni <a href> superstite a una
// riga "testo — url assoluto" — a differenza di extractProducts() serve
// sia il nome sia il link, quindi non si può ripulire tutto a solo testo
// come nelle altre funzioni AI (perderebbe gli href).
function extractLinksAsText(html: string, baseUrl: string): string {
  const cleaned = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<nav[\s\S]*?<\/nav>/gi, ' ')
    .replace(/<footer[\s\S]*?<\/footer>/gi, ' ');
  const lines: string[] = [];
  const re = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]{0,200}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(cleaned)) && lines.length < MAX_LINKS_FOR_AI) {
    let link: string;
    try { link = new URL(m[1], baseUrl).toString(); } catch { continue; }
    const text = decodeEntities(stripTags(m[2])).trim();
    if (text) lines.push(`${text} — ${link}`);
  }
  return lines.join('\n').slice(0, MAX_LINKS_TEXT_CHARS);
}

// Fallback quando extractProducts() (regex) non trova nulla. Ritorna []
// (mai un errore proprio) se anche l'AI non trova vini — chi chiama torna
// così al normale messaggio "nessun vino trovato".
async function extractProductsWithAI(html: string, baseUrl: string): Promise<{ name: string; link: string }[]> {
  const linksText = extractLinksAsText(html, baseUrl);
  if (!linksText) return [];

  const promptText = `Ecco l'elenco dei link presenti nella pagina di un sito di una cantina vinicola, nel formato "testo del link — url". Individua SOLO quelli che portano alla scheda di un vino specifico in vendita (non categorie, non "vedi tutti i prodotti", non carrello/account/lingua/social/contatti/blog). Rispondi SOLO con un array JSON valido, zero testo extra, zero markdown, nello schema [{"name":"","link":""}]. "name" è il nome del vino come appare nel testo del link, ripulito. Se non trovi nessun vino, rispondi con un array vuoto [].\n\n${linksText}`;

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
    console.error('Anthropic API error:', aiResp.status, await aiResp.text());
    return [];
  }

  const aiData = await aiResp.json();
  const responseText = (aiData.content || []).map((b: any) => b.text || '').join('');
  try {
    const parsed = JSON.parse(responseText.replace(/```json|```/g, '').trim());
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((p: any) => p?.name && p?.link).map((p: any) => ({ name: String(p.name), link: String(p.link) }));
  } catch {
    return [];
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) return json({ error: 'Devi essere autenticato' }, 200);

    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: userData, error: userErr } = await sbAdmin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: 'Sessione non valida' }, 200);

    const body = await req.json().catch(() => ({}));
    const wineryId = typeof body?.wineryId === 'string' ? body.wineryId : '';
    const shopUrl = typeof body?.shopUrl === 'string' ? body.shopUrl.trim() : '';
    if (!wineryId || !shopUrl) return json({ error: 'wineryId e shopUrl sono obbligatori' }, 200);

    let parsed: URL;
    try { parsed = new URL(shopUrl); } catch { return json({ error: 'Link non valido' }, 200); }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return json({ error: 'Link non valido' }, 200);

    const { data: winery } = await sbAdmin.from('wineries').select('id,owner_user_id').eq('id', wineryId).maybeSingle();
    if (!winery) return json({ error: 'Cantina non trovata' }, 200);

    // Ammesso anche il proprietario collegato della cantina stessa, non
    // solo l'admin — stesso permesso che ha già lato client su scheda e
    // catalogo (vedi canManageWinery() in index.html).
    const { data: profile } = await sbAdmin.from('profiles').select('is_admin').eq('id', userData.user.id).maybeSingle();
    const isOwner = winery.owner_user_id && winery.owner_user_id === userData.user.id;
    if (!profile?.is_admin && !isOwner) return json({ error: 'Non hai i permessi per farlo' }, 200);

    const pageResp = await fetchWithTimeout(parsed.toString());
    if (!pageResp.ok) return json({ error: `Impossibile raggiungere la pagina (${pageResp.status})` }, 200);
    const html = (await pageResp.text()).slice(0, MAX_HTML_BYTES);

    let found: { name: string; link: string }[] = [];
    if (isSingleProductPath(parsed.pathname)) {
      const h1 = extractH1(html);
      if (h1) found = [{ name: h1, link: parsed.toString() }];
    }
    if (!found.length) found = extractProducts(html, parsed.toString());
    if (!found.length) found = await extractProductsWithAI(html, parsed.toString());
    if (!found.length) {
      return json({ error: 'Nessun vino trovato su quella pagina: prova un link diverso (es. la pagina del negozio invece che una vetrina) o aggiungi i vini a mano.' }, 200);
    }

    const { data: existing } = await sbAdmin.from('winery_wines').select('name,link').eq('winery_id', wineryId);
    const existingNames = new Set((existing || []).map(e => e.name.trim().toLowerCase()));
    const existingLinks = new Set((existing || []).map(e => e.link).filter(Boolean));

    const toInsert = found.filter(p => !existingNames.has(p.name.trim().toLowerCase()) && !existingLinks.has(p.link));
    if (toInsert.length) {
      const { error: insErr } = await sbAdmin
        .from('winery_wines')
        .insert(toInsert.map(p => ({ winery_id: wineryId, name: p.name, link: p.link })));
      if (insErr) return json({ error: 'Errore salvataggio: ' + insErr.message }, 200);
    }

    return json({ ok: true, found: found.length, imported: toInsert.length, skipped: found.length - toInsert.length });
  } catch (err) {
    console.error(err);
    return json({ error: 'Errore interno' }, 200);
  }
});
