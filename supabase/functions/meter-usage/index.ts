import { createWorkerHandler, type WorkerName } from "../_shared/worker.ts";

const worker = "meter-usage" as WorkerName;

export const fetch = createWorkerHandler({ worker });
export default { fetch };
