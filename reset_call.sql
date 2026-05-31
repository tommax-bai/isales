UPDATE device SET status='idle' WHERE id=3;
UPDATE lead SET status='new', next_call_at=now() WHERE id=9;
