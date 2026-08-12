// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Edge Function: send-feedback-email
//
// Invia direttamente (via Resend) le segnalazioni di bug e le
// richieste/idee compilate su contattaci.html, invece di appoggiarsi
// a mailto: (che salta a un client di posta spesso non configurato,
// specie da browser desktop). Richiede una sessione autenticata: sia
// per evitare che l'endpoint diventi un relay email anonimo aperto
// ad abusi, sia perché così possiamo riportare nel corpo dell'email
// chi ha scritto (nome ed email del profilo) senza doverlo chiedere
// nel form, e impostare reply_to sul suo indirizzo per poter
// rispondere direttamente dalla casella di posta.
// ════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const FROM_ADDRESS = 'Enoscrigno <noreply@enoscrigno.it>';
const TO_ADDRESS = 'enoscrigno@gmail.com';
const MAX_SUBJECT_LEN = 200;
const MAX_BODY_LEN = 5000;

const PREFIX: Record<string, string> = { bug: 'BUG: ', idea: 'TO BE: ' };
const LABEL: Record<string, string> = { bug: '🐛 Segnalazione bug', idea: '💡 Richiesta o idea' };

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

// Il subject e il body arrivano da testo libero dell'utente e finiscono
// dentro HTML dell'email: senza escaping, un mittente potrebbe iniettare
// markup nell'email letta dal team.
function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function feedbackEmailHtml(fromName: string, fromEmail: string, tipo: string, subject: string, message: string): string {
  return `
  <div style="font-family: Inter, Arial, sans-serif; background:#F8F5F1; padding:32px;">
    <div style="max-width:480px; margin:0 auto; background:#6B1839; border-radius:16px; padding:32px;">
      <h1 style="font-family: Georgia, serif; color:#F8F5F1; font-size:21px; margin:0 0 18px;">${LABEL[tipo] || '✉️ Nuovo messaggio'}</h1>
      <p style="color:#E6D2B4; font-size:13px; margin:0 0 3px;">Da: <strong style="color:#F8F5F1">${escapeHtml(fromName)}</strong> (${escapeHtml(fromEmail)})</p>
      <p style="color:#E6D2B4; font-size:13px; margin:0 0 20px;">Oggetto: <strong style="color:#F8F5F1">${escapeHtml(subject)}</strong></p>
      <div style="background:rgba(255,255,255,.08); border-radius:10px; padding:16px; color:#F8F5F1; font-size:14px; line-height:1.6; white-space:pre-wrap;">${message ? escapeHtml(message) : '<span style="opacity:.6">(nessun messaggio aggiuntivo)</span>'}</div>
    </div>
  </div>`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) return json({ error: 'Devi essere autenticato per inviare un messaggio' }, 401);

    const sbAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: userData, error: userErr } = await sbAdmin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: 'Sessione non valida' }, 401);

    const fromEmail = userData.user.email!;
    const { data: profile } = await sbAdmin.from('profiles').select('full_name').eq('id', userData.user.id).maybeSingle();
    const fromName = profile?.full_name || fromEmail;

    const body = await req.json().catch(() => ({}));
    const tipo = typeof body?.tipo === 'string' ? body.tipo : '';
    const subject = (body?.subject || '').toString().trim().slice(0, MAX_SUBJECT_LEN);
    const message = (body?.body || '').toString().trim().slice(0, MAX_BODY_LEN);
    if (!subject) return json({ error: 'Oggetto mancante' }, 400);

    const emailSubject = (PREFIX[tipo] || '') + subject;

    const resendResp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM_ADDRESS,
        to: [TO_ADDRESS],
        reply_to: fromEmail,
        subject: emailSubject,
        html: feedbackEmailHtml(fromName, fromEmail, tipo, subject, message),
      }),
    });

    if (!resendResp.ok) {
      const errText = await resendResp.text();
      console.error('Resend error:', errText);
      return json({ error: 'Invio email non riuscito' }, 502);
    }

    return json({ ok: true });
  } catch (err) {
    console.error(err);
    return json({ error: 'Errore interno' }, 500);
  }
});
