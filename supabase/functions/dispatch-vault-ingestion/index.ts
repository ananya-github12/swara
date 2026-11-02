import { createWorkerHandler, type WorkerName } from "../_shared/worker.ts";

const worker = "dispatch-vault-ingestion" as WorkerName;

export const fetch = createWorkerHandler({ worker });
export default { fetch };
