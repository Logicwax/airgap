# attestation/signers/

The `.asc` files here are the ASCII-armored PGP public keys of the
maintainer(s) authorised to attest builds. Single-maintainer repo:
one key, `2BDE9CDB6D0FAD15` (Matthew Brooks).

```
make sign      # sign attestation/manifest.txt with your own key
make verify    # check signatures in attestation/signatures/ against it
```

Verification uses an isolated keyring built only from this directory —
a signature only counts if it was made by a key committed here.

At build time these keys are shipped into the image under `~/gpg-keys`
and imported into the airgap user's keyring, so `gpg --list-keys` on the
box lists the authorised signers (secret keys are never baked in).

To authorise a new signer, commit their ASCII-armored public key to this
directory, e.g. `gpg --export --armor <keyid> > <keyid>.asc`.
