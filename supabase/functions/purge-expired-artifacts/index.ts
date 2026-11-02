import { createWorkerHandler, type WorkerName } from "../_shared/worker.ts";

const worker = "purge-expired-artifacts" as WorkerName;

export const fetch = createWorkerHandler({ worker });
export default { fetch };
