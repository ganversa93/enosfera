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
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

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

// Cerca coppie (link, nome) nei blocchi prodotto tipici di WooCommerce:
// un <a href="..."> seguito, entro poche centinaia di caratteri, da un
// titolo <h2>/<h3>. Il primo pattern punta alla classe standard
// "woocommerce-loop-product__title"; il secondo è un fallback più
// permissivo per temi che non la usano.
function extractProducts(html: string, baseUrl: string): { name: string; link: string }[] {
  const patterns = [
    /<a[^>]+href="([^"]+)"[^>]*>[\s\S]{0,500}?<h[23][^>]*class="[^"]*product[^"]*title[^"]*"[^>]*>([^<]+)<\/h[23]>/gi,
    /<a[^>]+href="([^"]+)"[^>]*>\s*<h[23][^>]*>([^<]+)<\/h[23]>/gi,
  ];
  const seen = new Map<string, string>();
  for (const re of patterns) {
    let m: RegExpExecArray | null;
    while ((m = re.exec(html)) && seen.size < MAX_PRODUCTS) {
      let link: string;
      try { link = new URL(m[1], baseUrl).toString(); } catch { continue; }
      const name = decodeEntities(m[2]);
      if (name && !seen.has(link)) seen.set(link, name);
    }
    if (seen.size) break;
  }
  return [...seen.entries()].map(([link, name]) => ({ name, link }));
}

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
    if (!profile?.is_admin) return json({ error: 'Solo l\'admin può farlo' }, 403);

    const body = await req.json().catch(() => ({}));
    const wineryId = typeof body?.wineryId === 'string' ? body.wineryId : '';
    const shopUrl = typeof body?.shopUrl === 'string' ? body.shopUrl.trim() : '';
    if (!wineryId || !shopUrl) return json({ error: 'wineryId e shopUrl sono obbligatori' }, 400);

    let parsed: URL;
    try { parsed = new URL(shopUrl); } catch { return json({ error: 'Link non valido' }, 400); }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return json({ error: 'Link non valido' }, 400);

    const { data: winery } = await sbAdmin.from('wineries').select('id').eq('id', wineryId).maybeSingle();
    if (!winery) return json({ error: 'Cantina non trovata' }, 404);

    const pageResp = await fetchWithTimeout(parsed.toString());
    if (!pageResp.ok) return json({ error: `Impossibile raggiungere la pagina (${pageResp.status})` }, 502);
    const html = (await pageResp.text()).slice(0, MAX_HTML_BYTES);

    const found = extractProducts(html, parsed.toString());
    if (!found.length) {
      return json({ error: 'Nessun vino trovato su quella pagina (funziona meglio con negozi WooCommerce)' }, 404);
    }

    const { data: existing } = await sbAdmin.from('winery_wines').select('name,link').eq('winery_id', wineryId);
    const existingNames = new Set((existing || []).map(e => e.name.trim().toLowerCase()));
    const existingLinks = new Set((existing || []).map(e => e.link).filter(Boolean));

    const toInsert = found.filter(p => !existingNames.has(p.name.trim().toLowerCase()) && !existingLinks.has(p.link));
    if (toInsert.length) {
      const { error: insErr } = await sbAdmin
        .from('winery_wines')
        .insert(toInsert.map(p => ({ winery_id: wineryId, name: p.name, link: p.link })));
      if (insErr) return json({ error: 'Errore salvataggio: ' + insErr.message }, 500);
    }

    return json({ ok: true, found: found.length, imported: toInsert.length, skipped: found.length - toInsert.length });
  } catch (err) {
    console.error(err);
    return json({ error: 'Errore interno' }, 500);
  }
});
