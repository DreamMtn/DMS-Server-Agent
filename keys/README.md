# Release public key

`release_key.pub.pem` belongs here once it has been generated.

Generate it **on a machine that is not the control plane**, with
`scripts/sign_agent_release.py keygen` from the DMS-Host-Controller repo:

- the **private** half never leaves that machine and is what signs every agent release;
- the **public** half goes here, and the installer writes it into each host's config;
- record the **fingerprint** in the control plane (Settings -> Hosting -> Agents) so the
  enrollment dialog can show it.

A host only ever installs an agent build signed by this key. That is what stops a compromise
of the hosting control plane from pushing code to a customer's server — so the private key
must never be copied onto it, and rotating the key later means reinstalling every agent.

Only the public key is ever committed here.
