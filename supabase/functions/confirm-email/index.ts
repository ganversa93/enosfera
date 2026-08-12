// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: confirm-email
//
// Chiamata da confirmed.html quando l'utente clicca il link ricevuto
// via email. Verifica il token, marca la conferma e imposta
// profiles.email_confirmed = true. Pubblica (nessun JWT richiesto):
// chi clicca il link nella propria email non ha necessariamente una
// sessione attiva su quel dispositivo/browser.
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json().catch(() => ({}));
    const tokenValue = (body?.token || '').trim();
    if (!tokenValue) {
      return json({ error: 'Token mancante' }, 400);
    }

    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: row, error: rowErr } = await sbAdmin
      .from('email_confirmations')
      .select('token, user_id, confirmed_at, sent_at')
      .eq('token', tokenValue)
      .maybeSingle();

    if (rowErr || !row) {
      return json({ error: 'invalid_token', message: 'Link di conferma non valido.' }, 404);
    }

    if (row.confirmed_at) {
      return json({ ok: true, already: true });
    }

    const ageHours = (Date.now() - new Date(row.sent_at).getTime()) / 3_600_000;
    if (ageHours > 48) {
      return json({ error: 'expired_token', message: 'Il link di conferma è scaduto. Richiedine uno nuovo dal tuo profilo.' }, 410);
    }

    await sbAdmin
      .from('email_confirmations')
      .update({ confirmed_at: new Date().toISOString() })
      .eq('token', tokenValue);

    await sbAdmin
      .from('profiles')
      .update({ email_confirmed: true })
      .eq('id', row.user_id);

    return json({ ok: true });
  } catch (err) {
    console.error(err);
    return json({ error: 'Errore interno' }, 500);
  }
});
