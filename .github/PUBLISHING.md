# Publishing a release

`install.sh` here is a **published copy**. Its source of truth is `installer/install.sh` in
the private DMS-Host-Controller repository. Edit it there, then copy it here — never the
other way round, or the two will drift.

1. Build and sign, on a machine that is not the control plane:

       python3 scripts/sign_agent_release.py build --version X.Y.Z --out dist/
       python3 scripts/sign_agent_release.py sign --key ~/.dms/release-keys/release_key.pem \
                                                  --version X.Y.Z --artifact dist/dms-agent-X.Y.Z.tar.gz

2. Create a GitHub Release tagged `vX.Y.Z` here and attach `dms-agent-X.Y.Z.tar.gz`.

3. In the control plane: Configuration -> Agent Releases -> New. Paste the version, SHA-256
   and signature, set the artifact URL, save, then Publish.

4. Roll out: put one host on the **canary** channel, confirm it comes back healthy, then use
   **Promote to stable** on the release record.

## If install.sh changed

Update `dms_host_controller.installer_sha256` in the control plane settings to the new
digest, or the enrollment dialog will tell operators to stop on a legitimate install:

    sha256sum install.sh
