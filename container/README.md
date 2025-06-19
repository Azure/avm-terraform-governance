# AVM Container Build

This repository contains the Dockerfile and related files for building the AVM container image. The container is designed to provide a consistent environment for running Terraform and related tools.

### Local Build

```bash
docker buildx build $(cat version.env | ./build-arg-generator.sh) --tag test .
```
### Vulnerability Scanning

Use trivy to scan the container image for vulnerabilities:

```bash
trivy image --scanners vuln localhost/test
```
