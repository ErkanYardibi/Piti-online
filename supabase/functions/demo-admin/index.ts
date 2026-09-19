import {createHandler} from './handler.mjs';
Deno.serve(createHandler({demoUrl:Deno.env.get('SUPABASE_URL')!,demoServiceKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!}));
