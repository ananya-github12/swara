import { authenticateUserRequest } from "../_shared/auth.ts";
import { RuntimeDatabase } from "../_shared/database.ts";
import { createAccountDeletionHandler } from "./handler.ts";

export const fetch = createAccountDeletionHandler({
  authenticate: authenticateUserRequest,
  createDatabase: async () => await RuntimeDatabase.fromEnvironment("api"),
  environment: (name) => Deno.env.get(name),
});
export default { fetch };
