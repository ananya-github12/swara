import { createWorkerHandler, type WorkerName } from "../_shared/worker.ts";

const worker = "account-export" as WorkerName;

export const fetch = createWorkerHandler({ worker });
export default { fetch };
