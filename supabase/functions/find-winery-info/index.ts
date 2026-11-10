// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: find-winery-info
//
// Livello 2 (a pagamento) del completamento automatico delle cantine:
// a differenza di enrich-winery-profile (che legge un sito web già
// noto), qui si parte dal solo NOME della cantina — Claude cerca da
// solo il sito ufficiale sul web (tool web_search, al massimo 2
// ricerche) e propone Sito/Paese/Regione/Provincia/Descrizione da
// rivedere, esattamente come enrich-winery-profile: questa funzione
// non scrive mai sul database, l'admin controlla e salva come sempre
// con "Salva scheda" (saveWineryDetails() in index.html).
//
// Usa claude-haiku-5-5 (il modello più economico che supporta
// web_search) invece di claude-haiku-4-5-20251001 usato altrove in
// questo progetto: qui il costo per chiamata è più alto delle altre
// funzioni AI del progetto (le ricerche web si pagano a parte, $10
// ogni 1000, più i token), quindi vale la pena scegliere il modello
// più economico disponibile. Vedi infer_wineries_from_wines() in
// supabase_schema.sql per il livello 1, gratuito (nessuna chiamata
// AI), da usare sempre prima su tutte le cantine: questa funzione
// serve solo per quelle che restano senza indizi tra i vini già
// inseriti dagli utenti.
//
// Solo admin, nessun limite di utilizzo automatico come scan_usage:
// è pensata per essere lanciata una cantina alla volta dalla sua
// scheda (vedi findWineryInfoOnline() in index.html), non in batch su
// centinaia di cantine insieme, così il costo resta sotto il
// controllo diretto di chi la richiama.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Notifica l'admin via email (stesso indirizzo già usato per le nuove
// registrazioni) quando questa funzione va in errore in modo imprevisto —
// prima si vedeva solo aprendo a mano i log di Supabase. Nessun limite di
// frequenza: se diventa rumoroso per un problema ricorrente, è già di per
// sé un segnale che va sistemato. Un fallimento qui non deve mai impedire
// la risposta di errore originale al client.
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

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

const COUNTRY_OPTIONS = ['Italia', 'Francia', 'Germania', 'Spagna', 'Stati Uniti', 'Cile', 'Argentina', 'Nuova Zelanda', 'Sud Africa', 'Australia', 'Altro'];

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

    const { data: winery, error: wineryErr } = await sbAdmin.from('wineries').select('name').eq('id', wineryId).maybeSingle();
    if (wineryErr || !winery) return json({ error: 'not_found', message: 'Cantina non trovata' }, 200);

    const promptText = `Cerca sul web il sito ufficiale del produttore di vino/cantina "${winery.name}". Usa al massimo 2 ricerche. Poi, come UNICO contenuto della tua risposta finale, scrivi SOLO un oggetto JSON valido (zero markdown, zero testo prima o dopo), schema: {"website":"","country":"","region":"","province":"","description":""}.\n\n"website" è l'URL del sito ufficiale se lo trovi con ragionevole certezza — stringa vuota se non è chiaro o se trovi solo omonimi diversi, non indovinare.\n"country" deve essere ESATTAMENTE uno tra questi valori: ${COUNTRY_OPTIONS.join(', ')} (stringa vuota se non è chiaro).\n"region" e "province" solo se la ricerca le rende chiare (per un'azienda italiana la provincia è quella della sede/cantina, es. "Verona"); altrimenti stringa vuota, non indovinare.\n"description" è una breve descrizione in italiano (2-3 frasi) della cantina basata SOLO su quanto trovato nella ricerca, in terza persona, senza inventare dettagli non confermati.`;

    const aiResp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-5-5',
        max_tokens: 1500,
        messages: [{ role: 'user', content: promptText }],
        tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 2 }],
      }),
    });

    if (!aiResp.ok) {
      const errText = await aiResp.text();
      console.error('Anthropic API error:', aiResp.status, errText);
      return json({ error: 'ai_error', message: 'Errore nella ricerca online. Riprova o compila a mano.' }, 200);
    }

    const aiData = await aiResp.json();
    // Prendiamo solo l'ULTIMO blocco di testo: prima di arrivare al JSON
    // finale, Claude può scrivere blocchi di testo intermedi ("Cerco il
    // sito di...") mescolati ai blocchi di ricerca — unirli tutti come
    // fanno le altre funzioni enrich-* romperebbe il parsing JSON.
    const textBlocks = (aiData.content || []).filter((b: any) => b.type === 'text' && b.text);
    const lastText = textBlocks.length ? textBlocks[textBlocks.length - 1].text : '';
    let extracted;
    try {
      extracted = JSON.parse(lastText.replace(/```json|```/g, '').trim());
    } catch {
      return json({ error: 'parse_error', message: 'Non sono riuscito a interpretare la ricerca. Riprova o compila a mano.' }, 200);
    }

    return json({ data: extracted });
  } catch (err) {
    console.error('find-winery-info error:', err);
    await notifyAdminError('find-winery-info', err);
    return json({ error: 'server_error', message: `Errore imprevisto: ${err instanceof Error ? err.message : String(err)}` }, 200);
  }
});
