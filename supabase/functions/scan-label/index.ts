// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: scan-label
//
// Riceve la foto di un'etichetta dal frontend, verifica che l'utente
// non abbia superato i limiti di utilizzo, chiama l'API Anthropic
// (chiave tenuta segreta qui, mai esposta al browser) e restituisce
// i dati del vino estratti.
//
// LIMITI DI SICUREZZA — letti dalla tabella scan_limits (riga singola),
// modificabili dall'admin dalla sezione "Monitoraggio Scan AI" senza
// bisogno di un redeploy. Se la riga non esiste ancora (database non
// ancora migrato) si ricade sugli stessi valori che erano fissi prima:
//   PER_USER_MONTHLY_LIMIT — quante scansioni può fare un singolo utente al mese
//   GLOBAL_MONTHLY_LIMIT   — quante scansioni totali sono permesse a TUTTA l'app al mese
//
// Se un limite viene superato, la funzione risponde con errore 429
// SENZA chiamare Anthropic — quindi non genera alcun costo.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const DEFAULT_PER_USER_MONTHLY_LIMIT = 40;    // scansioni per utente Premium al mese (fallback)
const DEFAULT_GLOBAL_MONTHLY_LIMIT   = 800;   // scansioni totali per TUTTA l'app al mese
const DEFAULT_FREE_TRIAL_LIMIT       = 5;     // scansioni di prova gratuite A VITA per chi non è Premium

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

    // ── 2. Stato dell'utente: Premium con piano, o prova gratuita a vita ──
    const { data: profile, error: profileErr } = await sbAdmin
      .from('profiles').select('ai_scan_enabled, scan_monthly_limit, free_scans_used').eq('id', userId).maybeSingle();
    if (profileErr || !profile) {
      return json({ error: 'not_enabled', message: 'Profilo non trovato.' }, 403);
    }
    const isPremium = !!profile.ai_scan_enabled;

    const { data: limitsRow } = await sbAdmin
      .from('scan_limits').select('per_user_monthly_limit, global_monthly_limit, free_trial_limit').eq('id', true).maybeSingle();
    const GLOBAL_MONTHLY_LIMIT = limitsRow?.global_monthly_limit ?? DEFAULT_GLOBAL_MONTHLY_LIMIT;
    const FREE_TRIAL_LIMIT = limitsRow?.free_trial_limit ?? DEFAULT_FREE_TRIAL_LIMIT;

    // Non Premium: 5 scansioni di prova gratuite A VITA (free_scans_used
    // non si azzera mai, a differenza di scan_usage sotto che è mensile) —
    // esaurite quelle, la scansione resta bloccata finché non si sceglie
    // un piano dal profilo.
    if (!isPremium && (profile.free_scans_used || 0) >= FREE_TRIAL_LIMIT) {
      return json({
        error: 'free_trial_exhausted',
        message: `Hai usato tutte le ${FREE_TRIAL_LIMIT} scansioni di prova gratuite. Scegli un piano Premium dal tuo profilo per continuare.`
      }, 403);
    }

    // ── 3. Controlla i limiti PRIMA di chiamare Anthropic ──
    // Il limite mensile per utente vale solo per chi è Premium (dipende
    // dal piano scelto, profiles.scan_monthly_limit — impostato dal
    // webhook Stripe, vedi premium_plans; scan_limits.per_user_monthly_limit
    // resta un fallback per chi ha ai_scan_enabled senza un piano
    // associato, es. abilitato a mano dall'admin). Chi è in prova
    // gratuita è già stato filtrato sopra dal limite a vita, non da
    // questo. Il limite globale invece vale sempre, per chiunque.
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
    if (isPremium) {
      const PER_USER_MONTHLY_LIMIT = profile.scan_monthly_limit ?? limitsRow?.per_user_monthly_limit ?? DEFAULT_PER_USER_MONTHLY_LIMIT;
      if (userCount >= PER_USER_MONTHLY_LIMIT) {
        return json({
          error: 'limit_user',
          message: `Hai raggiunto il limite di ${PER_USER_MONTHLY_LIMIT} scansioni AI questo mese. Riprova il mese prossimo o inserisci i dati manualmente.`
        }, 429);
      }
    }

    // ── 4. Leggi le immagini dal body della richiesta (fronte + eventuale retro,
    //      oppure una singola foto di un biglietto da visita) ──
    const { images, mode } = await req.json();
    if (!Array.isArray(images) || images.length === 0) {
      return json({ error: 'Immagine mancante' }, 400);
    }
    // images[i] = { media_type, base64 } — al massimo 2 (fronte + retro)
    const imageBlocks = images.slice(0, 2).map((img: { media_type: string; base64: string }) => ({
      type: 'image',
      source: { type: 'base64', media_type: img.media_type, data: img.base64 }
    }));

    // ── 5. Chiama Anthropic (chiave segreta, mai esposta al client) ──
    // "mode" sceglie lo schema: biglietto da visita (Contatti cantina) o
    // etichetta di vino (default, comportamento storico invariato).
    const promptText = mode === 'business_card'
      ? 'Analizza questa foto di un biglietto da visita ed estrai le informazioni di contatto visibili. Rispondi SOLO con JSON valido, zero testo extra, zero markdown. Schema: {"referente":"","telefono":"","email":"","cantina":""}. "referente" è il nome della persona, "cantina" è il nome dell\'azienda/cantina stampato sul biglietto. Campi non visibili: stringa vuota o null.'
      : images.length > 1
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
    // Oltre al contatore mensile sopra (che serve solo per monitoraggio/
    // limite globale), chi non è Premium consuma anche la prova gratuita
    // a vita — mai per chi è Premium, che non ne ha bisogno.
    if (!isPremium) {
      await sbAdmin.from('profiles').update({ free_scans_used: (profile.free_scans_used || 0) + 1 }).eq('id', userId);
    }

    return json({ data: parsed });

  } catch (err) {
    console.error('scan-label error:', err);
    await notifyAdminError('scan-label', err);
    return json({ error: 'server_error', message: 'Errore imprevisto. Riprova più tardi.' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
