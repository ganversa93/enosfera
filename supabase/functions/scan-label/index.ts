// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: scan-label
//
// Riceve la foto di un'etichetta dal frontend, verifica che l'utente
// non abbia superato i limiti di utilizzo, chiama l'API Anthropic
// (chiave tenuta segreta qui, mai esposta al browser) e restituisce
// i dati del vino estratti.
//
// LIMITI DI SICUREZZA (modifica queste due costanti per cambiarli):
//   PER_USER_MONTHLY_LIMIT — quante scansioni può fare un singolo utente al mese
//   GLOBAL_MONTHLY_LIMIT   — quante scansioni totali sono permesse a TUTTA l'app al mese
//
// Se un limite viene superato, la funzione risponde con errore 429
// SENZA chiamare Anthropic — quindi non genera alcun costo.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const PER_USER_MONTHLY_LIMIT = 40;    // scansioni per utente al mese
const GLOBAL_MONTHLY_LIMIT   = 800;   // scansioni totali per TUTTA l'app al mese

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function currentPeriod(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // ── 1. Verifica identità utente dal token JWT ──
    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) {
      return json({ error: 'Non autenticato' }, 401);
    }

    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: userData, error: userErr } = await sbAdmin.auth.getUser(token);
    if (userErr || !userData?.user) {
      return json({ error: 'Sessione non valida' }, 401);
    }
    const userId = userData.user.id;
    const period = currentPeriod();

    // ── 2. Verifica che l'utente abbia accesso alla funzione (flag premium) ──
    const { data: profile, error: profileErr } = await sbAdmin
      .from('profiles').select('ai_scan_enabled').eq('id', userId).maybeSingle();
    if (profileErr || !profile?.ai_scan_enabled) {
      return json({
        error: 'not_enabled',
        message: 'La scansione etichette con AI è una funzione premium non ancora attiva per il tuo account.'
      }, 403);
    }

    // ── 3. Controlla i due limiti PRIMA di chiamare Anthropic ──
    const { data: globalRow } = await sbAdmin
      .from('scan_usage').select('count').eq('scope', 'global').eq('period', period).maybeSingle();
    const globalCount = globalRow?.count || 0;
    if (globalCount >= GLOBAL_MONTHLY_LIMIT) {
      return json({
        error: 'limit_global',
        message: 'Limite mensile di scansioni AI raggiunto per tutta l\'app. Riprova il mese prossimo o inserisci i dati manualmente.'
      }, 429);
    }

    const { data: userRow } = await sbAdmin
      .from('scan_usage').select('count').eq('scope', userId).eq('period', period).maybeSingle();
    const userCount = userRow?.count || 0;
    if (userCount >= PER_USER_MONTHLY_LIMIT) {
      return json({
        error: 'limit_user',
        message: `Hai raggiunto il limite di ${PER_USER_MONTHLY_LIMIT} scansioni AI questo mese. Riprova il mese prossimo o inserisci i dati manualmente.`
      }, 429);
    }

    // ── 4. Leggi le immagini dal body della richiesta (fronte + eventuale retro) ──
    const { images } = await req.json();
    if (!Array.isArray(images) || images.length === 0) {
      return json({ error: 'Immagine mancante' }, 400);
    }
    // images[i] = { media_type, base64 } — al massimo 2 (fronte + retro)
    const imageBlocks = images.slice(0, 2).map((img: { media_type: string; base64: string }) => ({
      type: 'image',
      source: { type: 'base64', media_type: img.media_type, data: img.base64 }
    }));

    // ── 5. Chiama Anthropic (chiave segreta, mai esposta al client) ──
    const promptText = images.length > 1
      ? 'Analizza queste due foto della stessa bottiglia di vino (fronte etichetta e controetichetta) ed estrai tutte le informazioni visibili, combinando i dati da entrambe le immagini — la controetichetta spesso contiene dettagli aggiuntivi come importatore, gradazione esatta, annata o denominazione estesa non presenti sul fronte. Rispondi SOLO con JSON valido, zero testo extra, zero markdown. Schema: {"name":"","producer":"","vintage":null,"type":"Rosso|Bianco|Rosato|Spumante|Dolce|Passito|Altro","doc":"","grapes":"","region":"","province":"","country":"","abv":null}. Campi non visibili in nessuna delle due foto: stringa vuota o null.'
      : 'Analizza questa etichetta di vino ed estrai tutte le informazioni visibili. Rispondi SOLO con JSON valido, zero testo extra, zero markdown. Schema: {"name":"","producer":"","vintage":null,"type":"Rosso|Bianco|Rosato|Spumante|Dolce|Passito|Altro","doc":"","grapes":"","region":"","province":"","country":"","abv":null}. Campi non visibili: stringa vuota o null.';

    const aiResp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1000,
        messages: [{
          role: 'user',
          content: [
            ...imageBlocks,
            { type: 'text', text: promptText }
          ]
        }]
      })
    });

    if (!aiResp.ok) {
      const errText = await aiResp.text();
      console.error('Anthropic API error:', aiResp.status, errText);
      return json({ error: 'ai_error', message: 'Errore nella lettura dell\'etichetta. Riprova o inserisci i dati manualmente.' }, 502);
    }

    const aiData = await aiResp.json();
    const text = (aiData.content || []).map((b: any) => b.text || '').join('');
    let parsed;
    try {
      parsed = JSON.parse(text.replace(/```json|```/g, '').trim());
    } catch {
      return json({ error: 'parse_error', message: 'Non sono riuscito a interpretare l\'etichetta. Riprova con una foto più nitida.' }, 502);
    }

    // ── 6. Incrementa i contatori SOLO dopo una chiamata riuscita ──
    await sbAdmin.from('scan_usage').upsert({
      scope: 'global', period, count: globalCount + 1, updated_at: new Date().toISOString()
    });
    await sbAdmin.from('scan_usage').upsert({
      scope: userId, period, count: userCount + 1, updated_at: new Date().toISOString()
    });

    return json({ data: parsed });

  } catch (err) {
    console.error('scan-label error:', err);
    return json({ error: 'server_error', message: 'Errore imprevisto. Riprova più tardi.' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
