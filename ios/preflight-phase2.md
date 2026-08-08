# RASCAL iOS — Phase 2 (Capture) preflight

**Aug 8, 2026.** Branch `ios/phase2-capture`, off `ios/phase1-spine`.

## Verdict: PASSED on re-run (Aug 8, 2026, later the same day).

**First run FAILED at check 3** and the build did not start — the bucket did not exist and the
credential was still the `.env.example` placeholder. That is recorded below unchanged, because
what a failed gate found is worth keeping.

**Storage now exists and the round trip works**, so the capture build is cleared to proceed:

```
POST /v1/entries              -> 201
POST /v1/media/upload-url     -> 200, host rascal-media-dev.t3.storage.dev
PUT  <presigned>              -> 200, ETag "4edd3122…"
POST /v1/media/{id}/complete  -> 200
```

Storage is **Tigris**, not AWS — see `docs/tigris-setup.md`. Nothing in this project ever
needed an Amazon account; the gap was a missing `endpoint_url` on the boto3 client, now
configurable and defaulted to AWS so existing behaviour is unchanged.

Two findings from provisioning that the capture build has to respect:

- `chunk_bytes` is **`null`** on the single-PUT path, with `multipart: false`. C-3 must read
  and store the field and tolerate null, never hardcode 8MB.
- The ETag arrived **with no CORS rule configured**, confirming CORS is browser-enforced and
  irrelevant to `URLSession`. `blocked.md` §2 described it as a client blocker; it is not.

### Original verdict, first run: FAILED. The build did not start.

**No Swift was written for Part Two.** Check 3 — object storage — failed, and it is the one
check that cannot be worked around: the S3 bucket does not exist and no real credential is
configured. Per the brief, I did not stub it, did not point at a fake bucket, and did not
build the uploader against a guess.

| # | Check | Result |
|---|---|---|
| 1 | Phase 1 is green | **PASS** |
| 2 | Local API and permissions | **PASS** (usage descriptions were missing; fixed in-lane, see below) |
| 3 | **Object storage** | **FAIL — blocks the run** |
| 4 | Device reality | **PASS** |

---

### 1. Phase 1 is actually green — PASS

- Clean `xcodebuild` on the branch before any change: `** BUILD SUCCEEDED **`, zero errors.
- Full suite: `✔ Test run with 11 tests in 2 suites passed after 0.138 seconds.`
- `ios/lane-b-phase1-report.md` read (260 lines).

**Carried forward, not rediscovered:** the one discrepancy it recorded is that
`docs/api-contract.md` describes `/auth/apple` as returning
`{ access_token, refresh_token, user }`, while the real `SessionResponse` also carries
`token_type` and `expires_in`. The fixture is correct and the client already decodes all five.
Nothing to redo.

Also carried forward: `thumb_key` is null server-side, so every view must lay out with no
thumbnail — which is why C-4's preview is a local one.

### 2. Local API and permissions — PASS, after an in-lane fix

```
GET  /health                          → {"status":"ok","db":"ok"}
POST /v1/auth/dev-login               → 200, token pair
GET  /v1/children/{DEV_CHILD_ID}/today → 200, today populated (2 assignments)
```

`today` has 2 rather than 3 because the question was completed during Phase 1 verification and
now sits in `done_today`. Both remaining are `completion_mode: media` — precisely the cards
this phase exists to make completable.

**All three usage descriptions were missing** from `Info.plist` and `Info-Debug.plist`. As in
Phase 1, these are files this lane owns and the requirement was fully specified, so I added
them rather than leaving a blocker that would fail the next run for no reason. This is not the
kind of gap the stop rule is protecting against — it is not a stub, not a guess, and not
storage. Verified present in the built app bundle (3 keys), both plists still `plutil -lint`
clean and identical apart from the Debug-only ATS entry.

The strings are written to be read by a parent, not by a reviewer:

- **Photos** — "Add photos you have already taken to your child's archive. Nothing is read or
  uploaded unless you pick it."
- **Camera** — "Take a photo or video for today's prompt without leaving the app."
- **Microphone** — "Record your child's voice for the archive — the entries you will be most
  glad to have in twenty years."

### 3. Object storage — FAIL

The API's half of this works. The storage behind it does not exist.

**`POST /v1/media/upload-url` → 200**, with a well-formed response:

```
keys        chunk_bytes, expires_in, media_id, multipart, parts, s3_key, upload_url
media_id    02f26617-b833-42f8-8585-16bfb6783ed2
s3_key      children/{child}/entries/{entry}/{media}.jpg
upload host rascal-media-dev.s3.amazonaws.com     ← real S3, not localhost, not moto
```

**The `PUT` failed.** Real AWS answered — `Server: AmazonS3`, genuine `x-amz-request-id` — so
this is not a stub responding:

```
PUT → 400
AuthorizationQueryParametersError: Error parsing the X-Amz-Credential parameter;
the region 'us-east-2' is wrong; expecting 'us-east-1'
```

That message is misleading, so I probed further rather than chase the region:

```
HEAD https://rascal-media-dev.s3.amazonaws.com/  → 404
GET  .../?location                               → <Code>NoSuchBucket</Code>
                                                    <BucketName>rascal-media-dev</BucketName>
```

**The bucket does not exist.** The `us-east-1` in the error is just S3's global endpoint
answering for a name that resolves nowhere — chasing it would have been a wasted afternoon.

And the credential is the `.env.example` placeholder, unchanged:

```
AWS_ACCESS_KEY_ID = local-dev-access-key
X-Amz-Credential  = local-dev-access-key/20260808/us-east-2/s3/aws4_request
```

A real AWS key id begins `AKIA` or `ASIA` and is 20 characters. Even with the bucket created,
this signature could never validate.

`POST /v1/media/{id}/complete` was **not** attempted: there is no ETag to send, and calling it
with a fabricated one would have proven nothing except that the server accepts fabricated
input.

This is exactly the state `docs/blocked.md` §2 already describes — "there is no bucket and no
credential" — now confirmed against real AWS rather than inferred from config.

#### What I need from you

Run **section 2 of `../docs/DEPLOY.md`**: bucket, public-access block, versioning, encryption,
CORS, lifecycle rule, IAM user, access key. The IAM policy JSON is in that document ready to
paste. Then set the four S3 values in the repo-root `.env`:

```
S3_BUCKET=<the bucket you create>
S3_REGION=<its region>
AWS_ACCESS_KEY_ID=AKIA…
AWS_SECRET_ACCESS_KEY=…
```

`S3_REGION` and the bucket's actual region must match, or every presign fails with the
misleading message above.

**Two things that document already warns about, and which matter specifically to this phase:**

1. **The CORS rule must expose `ETag`.** C-3 reads the `ETag` response header off the PUT and
   passes it to `complete`. If CORS does not expose it, the header is invisible to the client
   and completion fails in a way that reads like a signature error — you would spend the day
   suspecting the presign.
2. **`chunk_bytes` came back `null`** on this single-PUT request, with `multipart: false`. That
   is consistent — it is the multipart part size and there are no parts here. Worth recording
   now because C-3 says never to hardcode 8MB: the client must read and store the field, and
   must tolerate it being null on the single-PUT path. I would have hit this on the first run
   and it is better known before the code is written than after.

I can re-run this preflight the moment the bucket and key exist. Nothing else is in the way.

### 4. Device reality — PASS

```
travis's iPhone   available (paired)   iPhone 15 Pro Max (iPhone16,2)
destination: { platform:iOS, arch:arm64, id:00008130-0012743C2EF0001C }
```

A physical device is registered and paired, so camera capture **can** be verified this run once
storage exists. Worth restating: the simulator has no camera, so C-4's capture entry point and
the whole of C-6 are device-only. PhotosPicker works in the simulator; capture does not.

---

## State of the branch

`ios/phase2-capture` contains exactly one change: the three usage descriptions in both plists.
No `Media/` directory, no uploader, no image pipeline, no composer changes. The app builds
clean and the Phase 1 suite still passes.

Nothing here is wasted when storage lands — the permission strings are required either way, and
the `chunk_bytes: null` finding is a bug avoided rather than a bug fixed.
