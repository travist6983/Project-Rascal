# Preflight — the readable archive (export HTML viewer)

Run on 2026-08-11 against a locally running API. **All four checks pass.** The gate is
open; this file is the record of what the viewer was built against.

The API ran as `uvicorn rascal.main:app` with `ENVIRONMENT=local` against the Postgres 16
on `localhost:5432` and a `moto` S3 server on `127.0.0.1:5555` (`S3_ENDPOINT_URL` pointed
at it). Docker is unavailable in this environment, so `make up` was not the route to
Postgres — a local Postgres 16 was already listening on the port `.env` names. Neither
substitution touches the export code path: `write_export` calls the same boto3 client and
the same zip writer either way.

The archive was seeded **through the HTTP API**, not through the ORM — `POST /v1/children`,
`POST /v1/debug/scheduler/run` across four months, `POST /v1/entries`,
`POST /v1/media/upload-url`, a real presigned `PUT` of real PNG and WAV bytes,
`POST /v1/media/{id}/complete`, `PATCH /v1/media/{id}/derived`, and one
`DELETE /v1/entries/{id}`. 50 entries, 24 media objects, one media row whose bytes were
deliberately never uploaded, one soft-deleted entry, one sealed letter that has not opened
and one that has.

---

## 1. A real export, and the shape of one entry

```
$ curl -s -o /tmp/export.zip "http://127.0.0.1:8000/v1/children/$CHILD_ID/export" \
    -H "Authorization: Bearer $TOKEN" -D /tmp/export.headers
```

```
HTTP/1.1 200 OK
content-disposition: attachment; filename="rascal-rascal-20260811.zip"
content-length: 59414
content-type: application/zip
x-rascal-export-entries: 50
x-rascal-export-media: 24
x-rascal-export-missing-media: 1
```

```
$ unzip -l /tmp/export.zip
      381  media/2026/04/3e77c92b-bf28-4a97-a4cd-133f1ca9f2b7.png
    24044  media/2026/04/a98db5a5-ae1b-40f6-86f7-1afa27c32a58.wav
      ... 24 media objects, foldered 2026/04 .. 2026/08 ...
    68766  entries.json
      913  manifest.json
---------
   197145  26 files
```

One entry object, verbatim from `entries.json`:

```json
{
  "id": "1e4468ed-a5c6-464b-9dc3-0d796513bf24",
  "child_id": "bd54e295-87b3-4922-8e9d-72f5e9a77a85",
  "assignment_id": "4ed1bd98-bf1a-4a65-be7a-fb6edbf34722",
  "author_id": "39034965-9743-4db1-b8b6-06ec120cd2f1",
  "occurred_at": "2026-04-16T21:30:00+00:00",
  "created_at": "2026-08-11T23:25:17.287141+00:00",
  "updated_at": "2026-08-11T23:25:17.363009+00:00",
  "child_age_months": 58,
  "title": null,
  "body": "Caught it.",
  "entry_type": "photo",
  "unlock_at_age": null,
  "deleted_at": null,
  "is_deleted": false,
  "prompt": {
    "id": "59b511f4-3277-49ac-be6f-d00872c9d616",
    "kind": "photo",
    "cadence": "daily",
    "completion_mode": "media",
    "body": "Photograph his shoes by the door.",
    "theme": "everyday-ordinary"
  },
  "tags": [
    {"id": "d8d74b27-…", "name": "making", "source": "user", "deleted_at": null}
  ],
  "media": [
    {
      "id": "3e77c92b-bf28-4a97-a4cd-133f1ca9f2b7",
      "kind": "photo",
      "path": "media/2026/04/3e77c92b-bf28-4a97-a4cd-133f1ca9f2b7.png",
      "s3_key": "children/…/entries/…/3e77c92b-….png",
      "bytes": 381,
      "duration_seconds": null,
      "captured_at": "2026-08-11T23:25:17.359925+00:00",
      "transcript": null,
      "caption": null,
      "upload_status": "complete",
      "deleted_at": null,
      "is_deleted": false
    }
  ]
}
```

### Field by field, and which the viewer consumes

| Field | Present | Viewer uses it |
|---|---|---|
| `id` | yes | routing — `#entry/<id>` |
| `child_id` | yes | no |
| `assignment_id` | yes | no — the prompt is already inlined |
| `author_id` | yes | no |
| `occurred_at` | yes, ISO 8601 **normalised to `+00:00`** | **every date the viewer renders**, and the sort |
| `created_at` | yes | detail view only, labelled "logged" |
| `updated_at` | yes | no |
| `child_age_months` | yes | no — age is recomputed from the manifest birthdate |
| `title` | yes, nullable | card title and detail title |
| `body` | yes, nullable | card body, detail body, search |
| `entry_type` | yes — one of `photo` `video` `audio` `text` `did_it` | the kind chip, the did-it treatment |
| `unlock_at_age` | yes, nullable | the sealed-letter decision |
| `deleted_at` | yes, nullable | shown on a revealed deleted row |
| `is_deleted` | yes, boolean — **both forms are present** | the hide-by-default filter |
| `prompt` | yes, nullable object | the quoted prompt on the card, and search |
| `prompt.kind` | yes | colour: `question`/`audio` periwinkle, the rest terracotta |
| `prompt.body` | yes | the quoted prompt |
| `prompt.cadence`, `.completion_mode`, `.theme` | yes | not rendered |
| `tags[].name` | yes | chips, and search |
| `tags[].source` | yes | not rendered |
| `tags[].deleted_at` | yes | gated behind the same deleted toggle |
| `media[].kind` | yes — `photo` `video` `audio` | picks `<img>` / `<video>` / `<audio>` |
| `media[].path` | yes, **nullable** | the `src`; null means the bytes are not in the zip |
| `media[].transcript` | yes, nullable | rendered under the player, and search |
| `media[].caption` | yes, nullable | rendered under the player, and search |
| `media[].duration_seconds` | yes, nullable | the duration on a voice band |
| `media[].bytes` | yes | shown on a missing-media note |
| `media[].s3_key` | yes | shown on a missing-media note |
| `media[].captured_at`, `.upload_status` | yes | detail view metadata |
| `media[].deleted_at` / `.is_deleted` | yes | gated behind the same deleted toggle |

Two things worth stating because they decided viewer behaviour:

- **`occurred_at` is serialized in UTC**, not in the family timezone it was recorded
  against. `2026-04-16T17:30-04:00` comes out as `2026-04-16T21:30:00+00:00`. A viewer that
  renders it in the reader's own zone will put evening entries on the wrong day. The viewer
  formats every date in `manifest.child.family_timezone`.
- **`occurred_at` and `created_at` really are different values** here — the archive was
  seeded today with occurred dates spread across four months. Nothing renders `created_at`
  as if it were the date of the moment.

## 2. The manifest — **it already carries the birthdate**

```json
{
  "format": "rascal-export",
  "format_version": 1,
  "generated_at": "2026-08-11T23:25:24.453243+00:00",
  "child": {
    "id": "bd54e295-87b3-4922-8e9d-72f5e9a77a85",
    "name": "Rascal",
    "birthdate": "2021-06-01",
    "family_timezone": "America/Detroit"
  },
  "counts": {"entries": 50, "deleted_entries": 1, "media": 24, "media_bytes": 127466},
  "missing_media": ["children/…/82a1e132-….png"],
  "notes": ["…"]
}
```

`child.birthdate` is present, as is `child.family_timezone`. **No API change is required
this phase.** `format` is `rascal-export` and `format_version` is `1`; the viewer asserts on
both and stays at version 1.

## 3. Media paths are explicit and relative — the viewer does not reconstruct them

Each media row carries its own `path`, relative to the zip root, written by the export
itself. The folder is derived from the entry's `occurred_at` (`_media_path` formats
`media/{entry.occurred_at:%Y/%m}/{media.id}{suffix}`), but the viewer never has to know
that — it reads the string.

Checked against the listing: `media/2026/04/3e77c92b-bf28-4a97-a4cd-133f1ca9f2b7.png` from
`entries.json` is byte-identical to the name in `unzip -l`.

**A media row whose bytes never reached S3 has `path: null`** — verified on the deliberately
unfinished upload — and its `s3_key` appears in `manifest.missing_media`. `path === null` is
the signal the viewer uses; it is per-row and does not require matching against the manifest
list.

## 4. The suite is green

```
$ make test
459 passed in 87.73s (0:01:27)
```

**That 459 is not this branch's baseline, and the difference is worth stating.** Preflight ran
on the branch that happened to be checked out — `claude/deploy-readiness-scheduler-5pr0uh`,
which carries unmerged Phase 19/20 work worth 13 tests. This branch was then cut from
`origin/main`, where the count is **446** (`pytest --collect-only`, measured by stashing this
branch's changes). 446 is the number the viewer's +21 is added to.

`docs/roadmap-status.md` says "265+" in one place and 446 in another. The 446 was accurate;
the 265+ was never close.
