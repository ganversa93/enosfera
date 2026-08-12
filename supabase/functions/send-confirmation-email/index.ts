// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: send-confirmation-email
//
// Invia una email di conferma indirizzo tramite Resend, del tutto
// indipendente dal sistema nativo di conferma di Supabase (che resta
// disattivato apposta: il login rimane immediato dopo la
// registrazione). Questa email è quindi puramente di verifica/
// benvenuto e non blocca mai l'accesso.
//
// Due modalità di chiamata:
//   1. Autenticata (JWT nell'header Authorization) — usata subito
//      dopo la registrazione o dal pulsante "Rinvia" nel profilo.
//      L'email usata è SEMPRE quella del token, mai quella nel body,
//      per evitare che si possa richiedere l'invio a un indirizzo
//      arbitrario.
//   2. Non autenticata, con { email } nel body — usata dal pulsante
//      "Rinvia" nella schermata di login, prima di aver ottenuto una
//      sessione. Per non rivelare quali indirizzi sono registrati,
//      risponde sempre con esito positivo, anche se l'email non
//      esiste o è già stata confermata.
//
// Un limite di 1 invio ogni 60 secondi per utente evita abusi/spam.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const FROM_ADDRESS = 'Enoscrigno <noreply@enoscrigno.it>';
const SITE_URL = 'https://www.enoscrigno.it';
const MIN_INTERVAL_SECONDS = 60;

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

const GENERIC_OK = { ok: true, message: 'Se l\'indirizzo è registrato, riceverai a breve una email di conferma.' };

function confirmationEmailHtml(link: string): string {
  return `
  <div style="font-family: Inter, Arial, sans-serif; background:#F8F5F1; padding:32px;">
    <div style="max-width:420px; margin:0 auto; background:#6B1839; border-radius:16px; padding:36px; text-align:center;">
      <h1 style="font-family: Georgia, serif; color:#F8F5F1; font-size:26px; margin:0 0 12px;">Conferma il tuo indirizzo</h1>
      <p style="color:#E6D2B4; font-size:15px; line-height:1.6; margin:0 0 28px;">
        Grazie per esserti registrato su Enoscrigno! Conferma il tuo indirizzo email cliccando il pulsante qui sotto.
      </p>
      <a href="${link}" style="display:inline-block; background:#B8892A; color:#2A1B0A; font-weight:600; font-size:15px; padding:13px 32px; border-radius:30px; text-decoration:none;">
        Conferma email
      </a>
      <p style="color:rgba(230,210,180,0.6); font-size:12px; margin-top:28px;">
        Se non hai richiesto tu questa registrazione, ignora pure questa email.
      </p>
    </div>
  </div>`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const body = await req.json().catch(() => ({}));

    let userId: string;
    let email: string;

    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace('Bearer ', '');

    if (token) {
      const { data: userData, error: userErr } = await sbAdmin.auth.getUser(token);
      if (userErr || !userData?.user) {
        return json({ error: 'Sessione non valida' }, 401);
      }
      userId = userData.user.id;
      email = userData.user.email!;
    } else {
      const requestedEmail = (body?.email || '').trim().toLowerCase();
      if (!requestedEmail) {
        return json({ error: 'Email mancante' }, 400);
      }
      const { data: foundId } = await sbAdmin.rpc('get_user_id_by_email', { lookup_email: requestedEmail });
      if (!foundId) {
        return json(GENERIC_OK);
      }
      userId = foundId as string;
      email = requestedEmail;
    }

    const { data: profile } = await sbAdmin
      .from('profiles').select('email_confirmed').eq('id', userId).maybeSingle();
    if (profile?.email_confirmed) {
      return json(GENERIC_OK);
    }

    const { data: lastRow } = await sbAdmin
      .from('email_confirmations')
      .select('sent_at')
      .eq('user_id', userId)
      .order('sent_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (lastRow?.sent_at) {
      const elapsed = (Date.now() - new Date(lastRow.sent_at).getTime()) / 1000;
      if (elapsed < MIN_INTERVAL_SECONDS) {
        return json(GENERIC_OK);
      }
    }

    const { data: inserted, error: insertErr } = await sbAdmin
      .from('email_confirmations')
      .insert({ user_id: userId, email })
      .select('token')
      .single();
    if (insertErr || !inserted) {
      return json({ error: 'Impossibile generare il link di conferma' }, 500);
    }

    const confirmLink = `${SITE_URL}/confirmed.html?token=${inserted.token}`;

    const resendResp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM_ADDRESS,
        to: [email],
        subject: 'Conferma il tuo indirizzo — Enoscrigno',
        html: confirmationEmailHtml(confirmLink),
      }),
    });

    if (!resendResp.ok) {
      const errText = await resendResp.text();
      console.error('Resend error:', errText);
      return json({ error: 'Invio email non riuscito' }, 502);
    }

    return json(GENERIC_OK);
  } catch (err) {
    console.error(err);
    return json({ error: 'Errore interno' }, 500);
  }
});
