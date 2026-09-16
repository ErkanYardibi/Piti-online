import {createHandler} from './handler.mjs';
// Gateway JWT checks are off because the one-time entry exchange has no session yet.
// All account-management actions verify the bearer token with Auth and then enforce
// the database role, current session, password gate, and client ownership.
Deno.serve(createHandler({url:Deno.env.get('SUPABASE_URL')!,serviceKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!}));
