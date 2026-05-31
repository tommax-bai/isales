"""Patch: add telephony.hangup() call in no_answer branch."""
import pathlib

p = pathlib.Path('/opt/isales/releases/20260517-222944/isales-engine/isales_engine/run_loop.py')
t = p.read_text()

old = '''        if not connected:
            sm.transition_to(
                CallStatus.END, reason="no_answer", force=True
            )
            session.hangup_cause = HangupCause.NO_ANSWER.value
            session.append_event("hangup", reason="no_answer", initiated_by="ai")
            return'''

new = '''        if not connected:
            await telephony.hangup(session.call_record_id)
            sm.transition_to(
                CallStatus.END, reason="no_answer", force=True
            )
            session.hangup_cause = HangupCause.NO_ANSWER.value
            session.append_event("hangup", reason="no_answer", initiated_by="ai")
            return'''

if old not in t:
    print("ERROR: target block not found")
    # Debug
    for i, line in enumerate(t.splitlines()):
        if 'not connected' in line:
            print(f"  L{i+1}: {line}")
else:
    t = t.replace(old, new, 1)
    p.write_text(t)
    print("OK: added telephony.hangup() before no_answer return")
