"""Small, in-memory control plane for a live browser agent run.

The browser is the authority on what happened.  This object deliberately does
not advance a run when it merely *sent* actions: it advances only when it gets
one atomic observation containing the matching action results and a freshly
extracted page.  Keeping this state out of the model prompt is what prevents a
late page update from making the next plan against the previous page.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from uuid import uuid4

from schemas import Action, ActionResult


MAX_EXECUTION_STEPS = 8


@dataclass(frozen=True)
class PendingActionBatch:
    """The one batch for which this session will accept an observation."""

    batch_id: str
    step: int
    actions: list[Action]

    @property
    def expected_field_ids(self) -> Counter[str]:
        return Counter(action.field_id for action in self.actions)


@dataclass
class ExecutionLoop:
    """Bounded plan → act → observe state for one user-requested run."""

    max_steps: int = MAX_EXECUTION_STEPS
    active: bool = False
    paused: bool = False
    # Resuming or skipping is deliberately not enough to act on the DOM we
    # happened to have before the control.  The client must provide a new page
    # snapshot (or an atomic action observation) before another batch can go
    # out.
    needs_fresh_page: bool = False
    completed_steps: int = 0
    pending: PendingActionBatch | None = None
    _issued_batch_ids: set[str] = field(default_factory=set)

    def start(self) -> None:
        """Start a new run, discarding any incomplete earlier run."""
        self.active = True
        self.paused = False
        self.needs_fresh_page = False
        self.completed_steps = 0
        self.pending = None

    def cancel(self) -> bool:
        """Make any late browser observation harmless."""
        changed = self.active or self.paused or self.pending is not None
        self.active = False
        self.paused = False
        self.needs_fresh_page = False
        self.pending = None
        return changed

    def pause(self) -> bool:
        """Stop autonomous continuation while retaining any in-flight batch.

        An already-issued browser action may still finish.  Its matching
        observation can be recorded, but no new actions may be issued until a
        later explicit resume and fresh page snapshot.
        """
        if not self.active or self.paused:
            return False
        self.paused = True
        return True

    def resume(self) -> bool:
        """Allow a paused run to continue only after fresh page evidence."""
        if not self.active or not self.paused:
            return False
        self.paused = False
        self.needs_fresh_page = True
        return True

    def skip_current_step(self) -> bool:
        """Invalidate, without completing, the batch the user chose to skip."""
        if not self.active or self.pending is None:
            return False
        self.pending = None
        self.needs_fresh_page = True
        return True

    def record_fresh_page(self) -> bool:
        """Accept fresh page context only when no batch is still outstanding."""
        if not self.active or self.pending is not None or not self.needs_fresh_page:
            return False
        self.needs_fresh_page = False
        return True

    @property
    def can_continue(self) -> bool:
        return (
            self.active
            and not self.paused
            and not self.needs_fresh_page
            and self.pending is None
            and self.completed_steps < self.max_steps
        )

    @property
    def at_limit(self) -> bool:
        return self.active and self.completed_steps >= self.max_steps

    def issue(self, actions: list[Action]) -> PendingActionBatch:
        """Reserve the next step before actions are sent to the browser."""
        if not actions:
            raise ValueError("Cannot issue an empty action batch.")
        if not self.can_continue:
            raise ValueError("This browser run cannot issue another action batch.")

        batch_id = str(uuid4())
        while batch_id in self._issued_batch_ids:
            batch_id = str(uuid4())
        batch = PendingActionBatch(
            batch_id=batch_id,
            step=self.completed_steps + 1,
            actions=list(actions),
        )
        self._issued_batch_ids.add(batch_id)
        self.pending = batch
        return batch

    def accept_observation(
        self, batch_id: str, results: list[ActionResult]
    ) -> PendingActionBatch:
        """Validate and consume the unique observation for the pending batch."""
        pending = self.pending
        if not self.active or pending is None:
            raise ValueError("There is no browser action batch awaiting observation.")
        if batch_id != pending.batch_id:
            raise ValueError("Observation does not match the pending action batch.")
        if len(results) != len(pending.actions):
            raise ValueError("Observation must report one result for every action.")
        if Counter(result.field_id for result in results) != pending.expected_field_ids:
            raise ValueError("Observation results do not match the pending actions.")

        self.pending = None
        self.completed_steps = pending.step
        # An atomic observation carries a freshly extracted page, so it is the
        # only in-flight result that may satisfy the post-resume freshness gate.
        self.needs_fresh_page = False
        return pending
