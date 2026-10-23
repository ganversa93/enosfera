// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: create-checkout-session
//
// Riceve la richiesta di upgrade a Premium dal frontend, crea (o
// riusa) un cliente Stripe per l'utente autenticato, e genera una
// sessione di pagamento Stripe Checkout (una pagina ospitata da
// Stripe stesso — l'app non vede né gestisce mai i dati della carta).
// Restituisce l'URL a cui reindirizzare il browser.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@17?target=deno';

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const STRIPE_PRICE_ID   = Deno.env.get('STRIPE_PRICE_ID')!;
const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const APP_URL           = Deno.env.get('APP_URL') || 'https://ganversa93.github.io/enosfera';

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Non autenticato' }, 401);

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: { user }, error: authErr } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''));
    if (authErr || !user) return json({ error: 'Non autenticato' }, 401);

    // Recupera o crea il cliente Stripe per questo utente
    const { data: profile } = await supabase.from('profiles').select('stripe_customer_id, full_name').eq('id', user.id).single();

    let customerId = profile?.stripe_customer_id;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email,
        name: profile?.full_name || undefined,
        metadata: { supabase_user_id: user.id },
      });
      customerId = customer.id;
      await supabase.from('profiles').update({ stripe_customer_id: customerId }).eq('id', user.id);
    }

    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      line_items: [{ price: STRIPE_PRICE_ID, quantity: 1 }],
      success_url: `${APP_URL}?premium=success`,
      cancel_url: `${APP_URL}?premium=cancelled`,
      client_reference_id: user.id,
    });

    return json({ url: session.url });
  } catch (err) {
    console.error('create-checkout-session error:', err);
    await notifyAdminError('create-checkout-session', err);
    return json({ error: err.message || 'Errore interno' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
