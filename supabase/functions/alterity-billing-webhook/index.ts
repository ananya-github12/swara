import { RuntimeDatabase } from "../_shared/database.ts";
import { verifyAlterityWebhookFromEnvironment } from "../_shared/alterity.ts";
import { createAlterityBillingWebhookHandler } from "./handler.ts";

export const fetch = createAlterityBillingWebhookHandler({
  verify: (request) => verifyAlterityWebhookFromEnvironment(request),
  createDatabase: async () => await RuntimeDatabase.fromEnvironment("api"),
});

export default { fetch };
