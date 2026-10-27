# Public source snapshot

This repository starts from Agent Guard 0.3.19 (build 30). Earlier development history and local build artifacts are kept in a separate private archive.

The public snapshot removes personal environment screenshots and the renderer that used those screenshots. Build signing identity is supplied through an environment variable. Release builds remap source and temporary build paths to generic paths.

The public package is a local-code-signed prerelease, not an Apple-notarized distribution. Existing functionality and hardware validation limits are described in README and VALIDATION-0.3.19.md. Publication checks do not replace a new physical input/display/authentication regression.

No third-party credentials, private signing key or personal machine configuration is included. This repository does not yet declare a general open-source reuse license; third-party product names remain their owners' property.
