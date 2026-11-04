"""What the console is doing RIGHT NOW, one entry per box and one for the fleet.

An action that changes a box (pause, restart, power, force-stop, a message,
a credential) CLAIMS that box for its duration; a second action on the same
box while it runs is refused `409 busy`, with the first one named, and fires
nothing. A fleet-wide action (start-all, stop-all, wake-silent) claims the
fleet slot — one at a time — and then each box only while its own call runs:
a box another action already holds is left alone and said so, never queued
behind it, so two operators and two tabs cannot double-fire one box.

Claims are non-blocking by design: waiting on a lock inside an HTTP request
would hold a thread per click and answer the second operator minutes later
with an action they no longer remember asking for. Busy is an answer.

The registry is also what the page reads (`GET /api/actions`) to draw what is
in flight in EVERY tab — the spinner on the box being restarted, its current
step, the fleet action's progress — not only in the tab that clicked.
"""

import threading
import time


class Inflight:
    def __init__(self):
        self._lock = threading.Lock()
        self._boxes = {}
        self._fleet = None

    def claim_box(self, box, action, actor=""):
        """(True, None) and the box is this action's, or (False, holder)."""
        with self._lock:
            held = self._boxes.get(box)
            if held is not None:
                return False, dict(held)
            self._boxes[box] = {"action": action, "actor": actor or "", "since": time.time(),
                                "step": ""}
            return True, None

    def step(self, box, step, action=None):
        """The step a claimed box's action is on (a restart's down, then
        start). Only the HOLDER's: a message, which does not claim its box,
        must not blank the step of the restart that does (round 11)."""
        with self._lock:
            held = self._boxes.get(box)
            if held is not None and (action is None or held["action"] == action):
                held["step"] = step or ""

    def release_box(self, box):
        with self._lock:
            self._boxes.pop(box, None)

    def claim_fleet(self, action, actor=""):
        with self._lock:
            if self._fleet is not None:
                return False, dict(self._fleet)
            self._fleet = {"action": action, "actor": actor or "", "since": time.time(),
                           "total": 0, "done": 0}
            return True, None

    def fleet_total(self, total):
        with self._lock:
            if self._fleet is not None:
                self._fleet["total"] = int(total)

    def fleet_done(self):
        with self._lock:
            if self._fleet is not None:
                self._fleet["done"] += 1

    def release_fleet(self):
        with self._lock:
            self._fleet = None

    def snapshot(self, now=None):
        """What is in flight, with each entry's age — the page's whole view."""
        now = time.time() if now is None else now
        with self._lock:
            boxes = {b: dict(e, age=int(now - e["since"])) for b, e in self._boxes.items()}
            fleet = dict(self._fleet, age=int(now - self._fleet["since"])) if self._fleet else None
        return {"boxes": boxes, "fleet": fleet}


INFLIGHT = Inflight()


def busy_reply(action, box, holder):
    """The 409 a claim refused: who holds it, doing what, for how long, and
    that nothing ran."""
    age = int(time.time() - holder.get("since", time.time()))
    what = holder.get("action", "?") + (" (%s)" % holder["step"] if holder.get("step") else "")
    by = (" by %s" % holder["actor"]) if holder.get("actor") else ""
    target = box if box else "the fleet"
    return 409, {"ok": False, "action": action, "refused": True, "busy": True,
                 "holder": holder,
                 "error": "%s is busy: %s, %ds in%s — nothing was run; it will be free when that finishes"
                          % (target, what, age, by)}
