# Native zero-trust model

This document maps the native shell/bridge work to a zero-trust security posture for autonomous or agent-driven desktop apps. The target is: **trust nothing, verify every bridge action, assume compromise, and minimize agency**.

## Design principles

- **Never trust the renderer.** Treat every WebView frame, script, and bridge payload as untrusted until it proves origin, session capability, command allowlist, and permission.
- **Least agency.** Grant only the specific native commands an app needs. Permissions are coarse classes; `security.bridge.allowed_commands` is the finer-grained enforcement layer.
- **Assume breach.** A compromised renderer should not gain broad native/file/network/update authority. Native commands fail closed unless their independent checks pass.
- **Make attacks impossible, not tedious.** Prefer cryptographic/session-bound capabilities and nonexistent code paths over rate limits or obscurity.
- **Static supply chain.** Dynamic native plugins are intentionally deferred; app commands are statically registered and validated before dispatch.

## Implemented controls

| Zero-trust capability | mer native control |
|---|---|
| Verifiable request context | macOS extracts the `WKScriptMessage` frame origin before dispatch. |
| Session-scoped bridge capability | `shell.zig` generates a 256-bit random token per native process; `macos.zig` captures it inside the injected shim; `bridge.zig` requires token validation by default and rejects envelopes with missing/invalid tokens before command lookup; native responses must echo the same token before the shim resolves a pending Promise. |
| Deny-by-default command surface | Unknown commands return `UnknownCommand`; custom commands are invalid unless they use a non-reserved app namespace and non-empty permission. |
| Least-agency allowlisting | Production gates require non-empty `security.bridge.allowed_commands` and `security.bridge.command_origins`. Custom commands additionally require explicit allowlisting. |
| Origin isolation | Runtime loopback origin is injected after port binding; production manifest origins must not include broad loopback/localhost entries. Navigation to non-allowed origins is cancelled. |
| Parameter/resource boundaries | Payloads are capped at 64 KB; `open.external` is scheme-allowlisted and rejects malformed/native-ambiguous URLs; `open.path` fails closed without explicit roots and canonicalizes paths before opening. |
| Supply-chain/update integrity | Update feeds require strict HTTPS, Ed25519 signatures over canonical metadata, anti-replay `metadata_version`, platform uniqueness, and artifact size/SHA-256 verification. Automatic install is deferred. |
| Platform fail-closed | Native shell and command backend are macOS-only today; Linux/Windows stubs return `UnsupportedPlatform` until origin extraction, path canonicalization, and packaging gates are implemented. |
| Production configuration integrity | `zig build native-prod-check` rejects missing signing/notarization/update/security hardening fields. Manifest configuration is version-controlled ZON imported at comptime. |

## Threat model notes

The session bridge token prevents ad-hoc/foreign `WKScriptMessage` posts from reaching command handlers, and the shim also requires the token on native responses before resolving a pending Promise. It is not a substitute for XSS prevention: code already executing in the trusted app page can still call `window.mer.invoke`. That is why the token is layered with origin checks, explicit command allowlists, permission classes, path/URL parameter validation, and production gates.

The embedded loopback HTTP server remains a local trust boundary. Native mode therefore requires numeric loopback bind hosts and injects the exact runtime origin after the server binds an ephemeral port. Production manifests should not add broad loopback or localhost origins.

## Required production posture

Before distributing a native app, run:

```bash
zig build native-prod-check
zig build package-notarize -Doptimize=ReleaseSmall
```

The production manifest should include:

- numeric loopback server host (`127.0.0.1` or `::1` only);
- explicit non-loopback extra navigation origins only when truly needed;
- non-empty command allowlist and per-command origin bindings;
- minimal `permissions` matching only listed commands;
- narrow `open.external` schemes and explicit `open.path` roots;
- Developer ID signing identity and notarization profile;
- signed update feed config with a canonical Ed25519 public key;
- persisted highest accepted update `metadata_version` in the app's own storage.

## Remaining gaps before claiming mature zero trust

- Hardware-bound app/agent identity and remote attestation.
- Mutual TLS or equivalent service identity for any future remote native services.
- Immutable/append-only audit trails for native command execution.
- User approval prompts for high-risk commands and policy-driven step-up authorization.
- Automatic, signed, atomic update installation with durable rollback protection.
- Linux WebKitGTK and Windows WebView2 backends with equivalent origin/token/path/signing gates.
- External penetration test/security audit.

Until those land, describe mer native as **zero-trust-oriented and fail-closed**, not fully zero-trust certified.
