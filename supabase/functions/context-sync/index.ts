import { authenticateUserRequest } from "../_shared/auth.ts";
import { createContextSyncHandler } from "./handler.ts";

export const fetch = createContextSyncHandler({
  authenticate: authenticateUserRequest,
  environment: (name) => Deno.env.get(name),
});

export default { fetch };
