import { useCallback, useEffect, useMemo, useState } from 'react';
import { exportWorkflow, importWorkflow } from './serialization';
import { LocalWorkflowStore } from './storage';
import type { LocalWorkflow, WorkflowLibrary, WorkflowStorageAdapter } from './types';

/** Small side-panel hook; consumers choose when to display or invoke it. */
export function useLocalWorkflowLibrary(storage: WorkflowStorageAdapter): WorkflowLibrary {
  const store = useMemo(() => new LocalWorkflowStore(storage), [storage]);
  const [workflows, setWorkflows] = useState<LocalWorkflow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setWorkflows(await store.list());
      setError(undefined);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not load local workflows.');
    } finally {
      setLoading(false);
    }
  }, [store]);

  useEffect(() => { void refresh(); }, [refresh]);

  const save = useCallback(async (workflow: LocalWorkflow) => {
    await store.save(workflow);
    await refresh();
  }, [store, refresh]);

  const remove = useCallback(async (workflowId: string) => {
    await store.remove(workflowId);
    await refresh();
  }, [store, refresh]);

  const importJson = useCallback(async (serialized: string) => {
    const workflow = importWorkflow(serialized);
    await store.save(workflow);
    await refresh();
    return workflow;
  }, [store, refresh]);

  const exportJson = useCallback((workflowId: string) => {
    const workflow = workflows.find((candidate) => candidate.id === workflowId);
    if (!workflow) throw new Error('Workflow not found.');
    return exportWorkflow(workflow);
  }, [workflows]);

  return { workflows, loading, ...(error ? { error } : {}), refresh, save, remove, importJson, exportJson };
}
