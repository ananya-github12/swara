import { createWorkerHandler, type WorkerName } from "../_shared/worker.ts";

const worker = "reconcile-billing" as WorkerName;

export const fetch = createWorkerHandler({ worker });
export default { fetch };
