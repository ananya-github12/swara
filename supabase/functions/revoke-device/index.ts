import { authenticateUserRequest } from "../_shared/auth.ts";
import { RuntimeDatabase } from "../_shared/database.ts";
import { createRevokeDeviceHandler } from "./handler.ts";

export const fetch = createRevokeDeviceHandler({
  authenticate: authenticateUserRequest,
  createDatabase: async () => await RuntimeDatabase.fromEnvironment("api"),
  environment: (name) => Deno.env.get(name),
});

export default { fetch };
