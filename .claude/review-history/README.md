# Review history

`false-positives.json` is the memory of `/rascal-review`. A finding listed here is never
reported again, which is what stops the second review of a branch from repeating the argument
you already had with the first one.

Add an entry when a finding was wrong — not when it was right and you chose not to fix it. A
real defect you are deferring belongs in `TASK.md`; suppressing it here hides it from every
future review, including the one before the release that ships it.

```json
{
  "version": 1,
  "entries": [
    {
      "fingerprint": "a1b2c3d4e5f6",
      "file": "api/src/rascal/routers/sync.py",
      "rule": "Every read path filters deleted_at IS NULL",
      "reason": "/sync is the documented exception — it has to return deleted rows so the phone can delete them locally.",
      "added": "2026-08-11",
      "expires_at": null
    }
  ]
}
```

- **fingerprint** — copy it from the report. It is the first twelve hex characters of
  `sha256(rule|file|normalised code)`, computed by `merge_findings.py`. There is no line number
  in it on purpose: a suppression that expired every time someone inserted a line above would
  be worthless.
- **reason** — why the finding was wrong, in enough detail that you will believe it in six
  months. This file is read by people deciding whether a suppression still holds.
- **expires_at** — `null` for permanently wrong. A date for "wrong until that lands", which is
  the honest way to silence a finding that a planned change will make real or moot.

A finding whose code changes gets a new fingerprint and comes back on its own. That is the
design: suppression follows the exact code that was reviewed, not the file it lived in.
