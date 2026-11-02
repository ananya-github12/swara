import { MAX_STORED_WORKFLOWS, type LocalWorkflow, type WorkflowStorageAdapter } from './types';
import { validateWorkflow } from './serialization';

const STORAGE_KEY = 'swara.localWorkflows.v1';

/**
 * Local-only persistence. The injected adapter keeps this independent of
 * Chrome at test time and deliberately stores no account, Vault, or server data.
 */
export class LocalWorkflowStore {
  constructor(private readonly storage: WorkflowStorageAdapter, private readonly key = STORAGE_KEY) {}

  async list(): Promise<LocalWorkflow[]> {
    const stored = await this.storage.get(this.key);
    const raw = stored[this.key];
    if (raw === undefined) return [];
    if (!Array.isArray(raw)) throw new Error('Saved local workflows are corrupted.');
    if (raw.length > MAX_STORED_WORKFLOWS) throw new Error('Too many saved local workflows.');
    return raw.map(validateWorkflow).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  async save(workflow: LocalWorkflow): Promise<void> {
    const valid = validateWorkflow(workflow);
    const current = await this.list();
    const withoutExisting = current.filter((candidate) => candidate.id !== valid.id);
    if (withoutExisting.length >= MAX_STORED_WORKFLOWS) throw new Error(`You can save at most ${MAX_STORED_WORKFLOWS} local workflows.`);
    await this.storage.set({ [this.key]: [...withoutExisting, valid] });
  }

  async remove(workflowId: string): Promise<void> {
    const current = await this.list();
    await this.storage.set({ [this.key]: current.filter((workflow) => workflow.id !== workflowId) });
  }

  async clear(): Promise<void> {
    await this.storage.remove(this.key);
  }
}

export function createChromeLocalWorkflowStore(storage: WorkflowStorageAdapter): LocalWorkflowStore {
  return new LocalWorkflowStore(storage);
}

export { STORAGE_KEY as LOCAL_WORKFLOW_STORAGE_KEY };
