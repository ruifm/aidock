# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in aidock, please report it privately by emailing **security@ruimarques.xyz**.

Do not open a public issue for security vulnerabilities.

You should receive a response within 48 hours. I will work with you to understand the issue and coordinate a fix before any public disclosure.

## Scope

aidock is a container wrapper. Its security boundary is the container runtime (Podman or Docker). Issues that fall within scope include:

- Container escapes or privilege escalation caused by aidock's configuration
- Unintended exposure of host files, credentials, or environment variables
- Flaws in auth token handling or forwarding

Issues outside aidock's control (e.g., vulnerabilities in Podman, Docker, or the AI agents themselves) should be reported to the respective upstream projects.
