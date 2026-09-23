import {createHandler} from './handler.mjs';
Deno.serve(createHandler({url:Deno.env.get('SUPABASE_URL'),serviceKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
 origins:(Deno.env.get('ACCOUNT_DELETION_ORIGINS')||'').split(',').map(x=>x.trim()).filter(Boolean)}));
