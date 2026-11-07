// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: create-portal-session
//
// Apre il portale clienti di Stripe (pagina ospitata da Stripe) per
// l'utente autenticato, cosi' puo' gestire o annullare da solo il
// proprio abbonamento Premium senza bisogno di scrivere a un admin —
// lo stato su profiles si aggiorna comunque sempre tramite
// stripe-webhook, mai da qui direttamente.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@17?target=deno';

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const APP_URL           = Deno.env.get('APP_URL') || 'https://ganversa93.github.io/enosfera';

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Non autenticato' }, 401);

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: { user }, error: authErr } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''));
    if (authErr || !user) return json({ error: 'Non autenticato' }, 401);

    const { data: profile } = await supabase.from('profiles').select('stripe_customer_id').eq('id', user.id).maybeSingle();
    if (!profile?.stripe_customer_id) return json({ error: 'Nessun abbonamento associato a questo account' }, 400);

    const session = await stripe.billingPortal.sessions.create({
      customer: profile.stripe_customer_id,
      return_url: APP_URL,
    });

    return json({ url: session.url });
  } catch (err) {
    console.error('create-portal-session error:', err);
    await notifyAdminError('create-portal-session', err);
    return json({ error: err.message || 'Errore interno' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
