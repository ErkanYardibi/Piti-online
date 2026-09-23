import { createPushHandler } from "./handler.mjs";
Deno.serve(createPushHandler({ env: (key: string) => Deno.env.get(key) }));
