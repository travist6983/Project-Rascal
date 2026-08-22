# Trusted roots for App Store Server Notifications V2

Every `*.cer` in this directory is loaded as a **DER-encoded** trust anchor by
`rascal.services.app_store.load_root_certificates()`, and a notification's `x5c` chain must
terminate at one of them or the request is refused with `401`.

**Bundled rather than fetched.** A root downloaded at request time is a root that whoever
controls DNS at that moment gets to choose, which would make the chain verification decorative.

## What is here, and the endpoint fails closed when it is not

~~This directory is empty, and the endpoint fails closed until it is not.~~ — **struck Aug 22,
2026: `AppleRootCA-G3.cer` was fetched and committed that day, 583 bytes.**
`rascal.services.app_store.load_root_certificates()` now returns **one** anchor, and
`pytest -k "app_store or webhook"` passes 96 tests against it.

The fail-closed behaviour the struck heading described is unchanged and is not a thing to
"fix" if this directory is ever empty again: `POST /v1/webhooks/app-store` answers **`401` to
every notification** while no root is present, and logs the reason at `ERROR` naming this path.
There is no "accept it anyway" branch and adding one would defeat the only security control this
endpoint has.

**The blocker that kept this file out was environment-specific, not universal.** The branch that
wrote this code could not fetch it: `www.apple.com` was refused by the egress policy of the
environment phase 37a was built in, and Apple's root is not carried by the Mozilla trust store
(`certifi`) or by this image's system CA bundle, so there was nowhere honest to get the bytes.
That was true of *that* environment. It is one command anywhere with ordinary internet access,
and on Aug 22, 2026 it returned HTTP 200 first try:

```sh
curl -o api/src/rascal/certs/appstore/AppleRootCA-G3.cer \
  https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
```

### Checking what you got

Read the certificate before trusting it. The subject must be **Apple Root CA - G3**, and a root
is self-signed, so subject and issuer match:

```sh
openssl x509 -inform DER -in api/src/rascal/certs/appstore/AppleRootCA-G3.cer \
  -noout -subject -issuer -dates -fingerprint -sha256
```

The committed file answers `CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple
Inc., C=US` for both, valid `Apr 30 18:19:06 2014 GMT` → `Apr 30 18:19:06 2039 GMT`.

~~Compare the SHA-256 fingerprint against the one Apple publishes beside the download on
<https://www.apple.com/certificateauthority/>.~~ — **struck Aug 22, 2026: that instruction cannot
be followed, because Apple publishes no fingerprints there.** The page was fetched that day and
contains **zero** occurrences of "fingerprint" or "SHA-256"; it is a bare list of download links.
An instruction nobody can carry out is worse than none, because the step gets ticked anyway.

**The reason that instruction pointed away from this file still stands, and it is the part to
keep.** A fingerprint written into the repository beside the file it describes is a fingerprint
you would be checking against itself: whoever could substitute the `.cer` could substitute the
line, and the check would pass. **So there is no reference value in this README to compare
against** — the hash in the transcript below is a record of what one machine's keychain printed on
one day, not an authority. The second value has to be produced, now, from somewhere this
repository does not control.

**What is used instead — a genuinely independent second source.** Apple Root CA - G3 ships inside
macOS, in the system root keychain, put there by a different Apple distribution channel than the
web download. Export it and compare the bytes:

```sh
security find-certificate -a -c "Apple Root CA - G3" -Z \
  /System/Library/Keychains/SystemRootCertificates.keychain
# -> SHA-256 hash: 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179

cmp downloaded.der keychain.der   # -> identical, Aug 22, 2026
```

Two Apple-controlled channels, byte for byte identical. That is the check that was actually run.

**This is macOS-specific and does not generalise.** A Linux machine has no
`SystemRootCertificates.keychain` and `security` does not exist there, and Apple Root CA - G3 is
**not** in `ca-certificates` or in `certifi` — that absence is precisely why this file is
committed at all. Somebody verifying on Linux needs a different second source, and it must still
be produced outside this repository. Comparing against the hash in the transcript above is not
that: it is the self-check this section exists to refuse, and it is easier to do by accident here
than anywhere else, because the number is right there and it is correct.

Commit the `.cer` as a binary file. `AppleRootCA-G3.cer` is 583 bytes.

**Separately, and still open:** `APP_STORE_APP_APPLE_ID` is not set on `rascal-api` — confirmed
absent from `flyctl secrets list` on Aug 22, 2026. Apple's library only refuses to build a
verifier without it for `Environment.PRODUCTION`, so with the root in place the **sandbox**
verifier builds today and a first sandbox purchase is verifiable; **Production is not**, and
answers `401` until that secret is set. See `docs/blocked.md` §10a.

## Why G3 specifically

Apple signs App Store Server Notification payloads with a three-certificate chain that chains up
to **Apple Root CA - G3** (ECC, P-384). The other Apple roots — the original Apple Root CA, and
the Apple Root CA - G2 — do not sign these payloads. Adding them here would widen what this
endpoint trusts for nothing.

Apple's own verifier additionally requires the leaf to carry OID `1.2.840.113635.100.6.11.1` and
the intermediate `1.2.840.113635.100.6.2.1`, so a certificate that merely chains to an Apple root
is still not enough to write an entitlement.
