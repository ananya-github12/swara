import { authenticateUserRequest } from "../_shared/auth.ts";
import { RuntimeDatabase } from "../_shared/database.ts";
import { createBillingCheckoutHandler } from "./handler.ts";

export const fetch = createBillingCheckoutHandler({
  authenticate: authenticateUserRequest,
  createDatabase: async () => await RuntimeDatabase.fromEnvironment("api"),
  environment: (name) => Deno.env.get(name),
});
export default { fetch };
