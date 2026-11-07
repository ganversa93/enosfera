// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: stripe-webhook
//
// Riceve gli eventi da Stripe (pagamento riuscito, abbonamento
// rinnovato, annullato, ecc.) e aggiorna automaticamente
// ai_scan_enabled + lo stato dell'abbonamento sul profilo — nessun
// intervento manuale necessario da qui in avanti.
//
// La firma della richiesta viene sempre verificata: solo Stripe può
// davvero attivare/disattivare il Premium di qualcuno.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@17?target=deno';

const STRIPE_SECRET_KEY  = Deno.env.get('STRIPE_SECRET_KEY')!;
const STRIPE_WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Notifica l'admin via email (stesso indirizzo già usato per le nuove
// registrazioni) quando l'aggiornamento di un abbonamento fallisce in
// modo imprevisto — qui più che altrove conviene saperlo subito, perché
// significa che qualcuno ha pagato ma non ha ricevuto il Premium (o
// viceversa per una disdetta). Prima si vedeva solo aprendo a mano i log
// di Supabase. Nessun limite di frequenza: se diventa rumoroso per un
// problema ricorrente, è già di per sé un segnale che va sistemato. Non
// usata per una firma webhook non valida (sotto): quello è traffico di
// probing atteso, non un errore da segnalare.
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

// Dato il Price ID del primo item di un abbonamento, trova il piano
// corrispondente in premium_plans (nome gestito dall'admin, non qui) e
// restituisce il suo limite mensile di scansioni — null se il prezzo non
// corrisponde a nessun piano conosciuto (es. abbonamento legacy da prima
// dei piani a scaglioni): in quel caso scan_monthly_limit resta null e
// scan-label ricade sul limite globale di scan_limits.
async function resolvePlan(priceId: string | undefined) {
  if (!priceId) return { planId: null, limit: null };
  const { data } = await supabase.from('premium_plans').select('id, monthly_scan_limit').eq('stripe_price_id', priceId).maybeSingle();
  return data ? { planId: data.id, limit: data.monthly_scan_limit } : { planId: null, limit: null };
}

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error('Firma webhook non valida:', err);
    return new Response('Firma non valida', { status: 400 });
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session;
        const userId = session.client_reference_id;
        if (userId) {
          // Il piano scelto si ricava rileggendo l'abbonamento appena creato
          // (la sessione di checkout non porta direttamente il Price ID) —
          // in ogni caso arriverà anche un evento customer.subscription.created
          // subito dopo, che fa la stessa risoluzione: questo è solo per non
          // lasciare ai_scan_enabled attivo col piano sbagliato nella finestra
          // tra i due eventi.
          let planId: string | null = null, limit: number | null = null;
          const subId = session.subscription as string | null;
          if (subId) {
            const sub = await stripe.subscriptions.retrieve(subId);
            const resolved = await resolvePlan(sub.items.data[0]?.price?.id);
            planId = resolved.planId; limit = resolved.limit;
          }
          await supabase.from('profiles').update({
            ai_scan_enabled: true,
            subscription_status: 'active',
            stripe_subscription_id: subId,
            premium_plan_id: planId,
            scan_monthly_limit: limit,
          }).eq('id', userId);
        }
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted': {
        const sub = event.data.object as Stripe.Subscription;
        const active = sub.status === 'active' || sub.status === 'trialing';
        const { planId, limit } = active ? await resolvePlan(sub.items.data[0]?.price?.id) : { planId: null, limit: null };
        await supabase.from('profiles').update({
          ai_scan_enabled: active,
          subscription_status: sub.status,
          premium_plan_id: planId,
          scan_monthly_limit: limit,
        }).eq('stripe_customer_id', sub.customer as string);
        break;
      }
    }
    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('stripe-webhook error:', err);
    await notifyAdminError('stripe-webhook', err);
    return new Response('Errore interno', { status: 500 });
  }
});
