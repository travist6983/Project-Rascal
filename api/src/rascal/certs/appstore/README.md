# Trusted roots for App Store Server Notifications V2

Every `*.cer` in this directory is loaded as a **DER-encoded** trust anchor by
`rascal.services.app_store.load_root_certificates()`, and a notification's `x5c` chain must
terminate at one of them or the request is refused with `401`.

**Bundled rather than fetched.** A root downloaded at request time is a root that whoever
controls DNS at that moment gets to choose, which would make the chain verification decorative.

## This directory is empty, and the endpoint fails closed until it is not

`POST /v1/webhooks/app-store` answers **`401` to every notification** while no root is present,
and logs the reason at `ERROR` naming this path. That is deliberate: there is no "accept it
anyway" branch and adding one would defeat the only security control this endpoint has.

**The file could not be added on the branch that wrote this code.** `www.apple.com` is refused
by the egress policy of the environment phase 37a was built in, and Apple's root is not carried
by the Mozilla trust store (`certifi`) or by this image's system CA bundle, so there was nowhere
honest to get the bytes. It is one command on any machine with ordinary internet access:

```sh
curl -o api/src/rascal/certs/appstore/AppleRootCA-G3.cer \
  https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
```

Check what you got before committing it — the subject must be **Apple Root CA - G3**, and it is
self-signed, so subject and issuer match:

```sh
openssl x509 -inform DER -in api/src/rascal/certs/appstore/AppleRootCA-G3.cer \
  -noout -subject -issuer -dates -fingerprint -sha256
```

Compare the SHA-256 fingerprint against the one Apple publishes beside the download on
<https://www.apple.com/certificateauthority/>. **Compare it against Apple's page, not against a
value written here** — a fingerprint copied into this file is a fingerprint you would be
checking against itself.

Commit the `.cer` as a binary file. `AppleRootCA-G3.cer` is roughly 500 bytes.

## Why G3 specifically

Apple signs App Store Server Notification payloads with a three-certificate chain that chains up
to **Apple Root CA - G3** (ECC, P-384). The other Apple roots — the original Apple Root CA, and
the Apple Root CA - G2 — do not sign these payloads. Adding them here would widen what this
endpoint trusts for nothing.

Apple's own verifier additionally requires the leaf to carry OID `1.2.840.113635.100.6.11.1` and
the intermediate `1.2.840.113635.100.6.2.1`, so a certificate that merely chains to an Apple root
is still not enough to write an entitlement.
