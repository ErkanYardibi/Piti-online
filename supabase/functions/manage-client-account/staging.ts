import {createHandler} from './handler.mjs';
const url = Deno.env.get('SUPABASE_URL');
if (url !== 'https://ldufxzwgwbaogpmwqhlw.supabase.co') throw new Error('Wrong staging project');
// Authentication remains in the handler, including login and one-time entry.
Deno.serve(createHandler({url, serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  origins: ['https://piti-staging.erkan-yardibi.workers.dev']}));
