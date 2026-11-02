import { createWorkerHandler, type WorkerName } from "../_shared/worker.ts";

const worker = "complete-account-deletion" as WorkerName;

export const fetch = createWorkerHandler({ worker });
export default { fetch };
