# Private Docker Registry

A self-hosted CNCF Distribution Registry 3 for Docker and Kubernetes images. The public configuration uses `registry.example.com` as a placeholder. Replace it with your own hostname in the local `.env` file; do not commit that file.

The repository provides a secure-by-default local deployment plus optional production components for backups, VPS migration, Amazon S3 or Linode Object Storage, TLS termination, monitoring, retention, garbage collection, firewall rules, and image signing.

## Requirements

### Recommended server capacity

| Use case | CPU | Memory | Storage | Network |
| --- | ---: | ---: | --- | --- |
| Development or small lab | 2 vCPU | 4 GB RAM | 20 GB+ SSD | 100 Mbps+ |
| Production starting point | 4 vCPU | 8 GB RAM | SSD sized for all layers plus backups | 1 Gbps preferred |

The registry is storage-bound rather than CPU-bound. Size storage for the complete compressed image set, at least one local backup, temporary restore/maintenance space, and future growth. Keeping approximately 2x the current registry data size free is a practical starting point for backup, restore, and garbage-collection operations. This workstation currently uses approximately 3.1 GB for registry data, so its requirement will increase as more Kubernetes images are pushed.

### Operating system and runtime

- Linux server or workstation with a supported `amd64` or `arm64` Docker installation
- Docker Engine with the Compose v2 plugin (`docker compose`); the tested environment uses Docker Engine 29.8.1 and Compose 5.5.1
- A Docker daemon account with permission to run containers and manage the registry volume; `sudo` or root is required for firewall, system CA trust, and systemd installation steps
- OpenSSL, GNU Coreutils (`date`, `df`, `install`, `sha256sum`), `tar`, `gzip`, `awk`, `sed`, and `ss`/iproute2
- `curl` and `jq` for registry API, doctor, repository, image, and storage commands
- `skopeo` for bidirectional API-registry/Harbor migration, including multi-architecture images and OCI signature artifacts

### DNS, network, and ports

- A DNS or `/etc/hosts` entry pointing the registry hostname to this server; the hostname must resolve from Docker clients and Kubernetes nodes
- TCP `443` open for the registry’s HTTPS endpoint
- TCP `80` open only when using the Caddy/Let's Encrypt reverse-proxy deployment or HTTP ACME challenges
- The server’s SSH port must remain reachable before applying the firewall; the firewall script refuses to continue if it cannot verify an active or configured SSH port
- Outbound HTTPS access for pulling source images, Docker image downloads, optional Let's Encrypt certificates, and AWS/Linode S3 endpoints
- Enough network bandwidth for initial image imports, backups, migrations, and Kubernetes pulls

### Optional feature dependencies

- `ssh` and `scp` for VPS migration; passwordless SSH keys are recommended
- `crontab` for `registry backup schedule install`, or systemd for the files in `deploy/`
- `ufw` for `registry firewall check|plan|apply`
- `cosign` for `registry image sign` and `registry image verify`
- `kubectl` only on clients that create Kubernetes pull secrets; it is not required on the registry server
- An existing AWS S3 or Linode Object Storage bucket, credentials, and endpoint for the S3 storage profiles

The default deployment stores images in the Docker volume `private-docker-registry-data`. The AWS and Linode Compose profiles are alternatives to local storage; do not switch storage backends while the registry is writing, and plan a separate data migration for existing images.

Harbor GUI requires more resources than the lightweight registry: minimum 2 CPUs, 4 GB RAM, and 40 GB disk; 4 CPUs, 8 GB RAM, and 160 GB disk are recommended. See the [official Harbor prerequisites](https://goharbor.io/docs/edge/install-config/installation-prereqs/) before choosing the GUI deployment.

Check the installation:

```bash
docker --version
docker compose version
openssl version
```

## Installation

Clone the repository on the registry server and enter the directory:

```bash
git clone https://github.com/masharif46/Private-Docker-Registry.git Private-Docker-Registry
cd Private-Docker-Registry
```

Create the private configuration from the example:

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set:

```dotenv
REGISTRY_HOST=registry.example.com
REGISTRY_PORT=443
REGISTRY_USERNAME=registry-admin
REGISTRY_PASSWORD=use-a-long-random-password
REGISTRY_HTTP_SECRET=use-a-different-long-random-secret

# Optional monitoring and backup scheduling settings:
PROMETHEUS_PORT=9090
REGISTRY_BACKUP_SCHEDULE="0 2 * * *"
```

`REGISTRY_HOST`, `REGISTRY_PORT`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, and `REGISTRY_HTTP_SECRET` are required for the default deployment. `PROMETHEUS_PORT` is used by the optional monitoring Compose profile, and `REGISTRY_BACKUP_SCHEDULE` is used by `registry backup schedule install`. Keep the password and HTTP secret long, random, and different from each other.

The hostname must resolve from Docker clients and Kubernetes nodes. For a local test server, add an entry such as this on each client:

```text
192.0.2.10 registry.example.com
```

Initialize authentication and a development certificate, then start the registry:

```bash
./scripts/registry.sh init
./scripts/registry.sh up
./scripts/registry.sh status
```

### Interactive API-only or Harbor GUI installation

For a new server, the installer can ask which deployment you want:

```bash
./scripts/install.sh
```

Choose the lightweight CNCF Registry API deployment or Harbor GUI. The API-only option initializes this project’s existing deployment. The Harbor option downloads the pinned Harbor online installer, asks for the hostname and passwords, configures HTTPS certificate paths, enables Trivy scanning, and starts the Harbor web portal.

The Harbor option is intentionally protective: when the existing `private-docker-registry` container or `private-docker-registry-data` volume is present, it installs side-by-side on `harbor.<your-domain>` and HTTPS port `8443`, with separate Harbor data. It does not convert or delete existing registry images. Harbor can also be installed on a fresh/separate VPS. The installer saves the generated/admin credentials in `harbor/harbor-credentials.txt` with mode `600`; protect this file.

Container names use clear prefixes for operations on hosts running many containers: the lightweight registry is `private-docker-registry`, and Harbor services use names such as `private-harbor-core`, `private-harbor-registry`, `private-harbor-db`, and `private-harbor-nginx`. Renaming services recreates Harbor containers only; it does not remove Harbor data or the lightweight registry volume.

For non-interactive selection, use `./scripts/install.sh api-only` or `./scripts/install.sh harbor`. Harbor production installation requires an existing trusted certificate and private key; the installer can generate a self-signed certificate only for lab/testing. Harbor’s official installer and configuration remain authoritative for Harbor upgrades.

### Uninstalling safely

To stop and remove registry containers while preserving image data, credentials, certificates, Harbor files, and Docker volumes, run one of these commands:

```bash
./scripts/uninstall.sh api
./scripts/uninstall.sh harbor
./scripts/uninstall.sh all
```

The uninstall script never purges data by default. Permanent removal is a separate, explicit operation and requires both flags:

```bash
./scripts/uninstall.sh harbor --purge-data --confirm
./scripts/uninstall.sh api --purge-data --confirm
```

Review the exact target and keep a verified backup before using purge mode. Do not use Docker commands such as `docker compose down -v` manually unless you intentionally want to remove persistent volumes.

### Important: API registry and Harbor are separate registries

Installing Harbor does **not** convert the existing API registry and does not make Harbor a web view over it. A side-by-side installation creates two independent registries:

| Deployment | Example address | Data and accounts |
| --- | --- | --- |
| Lightweight CNCF Distribution Registry | `https://registry.example.com` | Existing registry volume, repositories, tags, and basic-auth users |
| Harbor GUI registry | `https://harbor.example.com:8443` | Separate Harbor database, projects, storage, users, RBAC, and image catalog |

The actual hostnames and ports come from the installer and `.env` configuration. On the same server, the two deployments must use different hostnames or ports. Logging into Harbor will **not** automatically show images previously pushed to the API registry, and API-registry users are not automatically created in Harbor. The installer deliberately does not perform a bulk migration, overwrite the existing registry, or delete its images.

#### Safe migration to Harbor

The recommended migration sequence is:

1. Keep the API registry running and take a verified backup.
2. Create the required Harbor projects and users.
3. Copy images and tags from the API registry into Harbor.
4. Verify repository names, tags, digests, sizes, and Kubernetes pull tests.
5. Keep the original registry untouched until the migration is accepted.
6. Redirect Docker and Kubernetes clients to Harbor only after verification.

Use the lightweight registry CLI to inspect the original catalog:

```bash
registry repo list
registry repo tags docker.io/library/nginx
registry image inspect docker.io/library/nginx:1.27
```

To make an existing image appear in Harbor, copy it into Harbor. This is a copy operation; the original image remains in the lightweight registry:

```bash
# Trust the local Harbor certificate on this Docker client.
sudo mkdir -p /etc/docker/certs.d/harbor.example.com:8443
sudo cp harbor/certs/harbor.crt \
  /etc/docker/certs.d/harbor.example.com:8443/ca.crt
sudo systemctl restart docker

docker login registry.example.com
docker login harbor.example.com:8443

docker pull registry.example.com/docker.io/library/nginx:1.27
docker tag registry.example.com/docker.io/library/nginx:1.27 \
  harbor.example.com:8443/docker.io/library/nginx:1.27
docker push harbor.example.com:8443/docker.io/library/nginx:1.27
```

For bulk copying, `skopeo` can copy an image without requiring a local Docker tag:

```bash
skopeo copy \
  docker://registry.example.com/team/app:v1 \
  docker://harbor.example.com:8443/team/app:v1 \
  --dest-tls-verify=false
```

Existing basic-auth users cannot normally be copied directly into Harbor because Harbor stores users in its own database. Recreate them through Harbor’s administration interface or CLI, or configure LDAP/OIDC so both systems use the same external identity provider. Basic authentication on the lightweight registry does not provide Harbor-style project-level RBAC.

Create the destination Harbor project before pushing. For example, the source repository `flowvaro/admin` maps to Harbor project `flowvaro` and repository `admin`; `docker.io/library/nginx` maps to Harbor project `docker.io` and repository `library/nginx`. Harbor’s web portal can create projects and manage project members/RBAC.

For a complete migration, enumerate every source repository and tag, create the corresponding Harbor projects, then copy every tag. Keep at least one verified backup and enough free disk for a second copy of the image set. Do not run garbage collection during migration, and do not delete the original registry until Harbor pulls, tags, authentication, and Kubernetes workloads have been tested. A future migration helper may automate this process, but it must still require explicit confirmation because copying dozens of repositories is a significant storage and network operation.

The registry is now available at `https://registry.example.com`. The default certificate is self-signed and suitable only for a private lab. For production, use a certificate issued by a trusted CA or place the registry behind a TLS reverse proxy.

## Pinned component versions

| Component | Version | Purpose |
| --- | --- | --- |
| CNCF Distribution Registry | `3.1.1` | OCI image storage and distribution |
| Caddy | `2.11.4` | Optional trusted TLS reverse proxy |
| Prometheus | `3.13.3` LTS | Optional metrics collection |
| Alpine Linux | `3.22` | Isolated backup and restore helper |

## Trusting the development certificate

Docker clients must trust the generated certificate before login. Copy the certificate securely to each Docker host, then run this from the directory containing the copied certificate:

```bash
sudo mkdir -p /etc/docker/certs.d/registry.example.com
sudo cp ./registry.crt /etc/docker/certs.d/registry.example.com/ca.crt
sudo systemctl restart docker
```

For Kubernetes, install the same CA certificate on every node/container runtime according to that runtime's certificate-trust instructions. A trusted CA certificate is recommended for production because it avoids this manual step.

## Login and push images

There are two independent login targets when Harbor is installed:

| Command | Login target | Credentials |
| --- | --- | --- |
| `registry login` | Lightweight API registry at `REGISTRY_HOST` from `.env` | `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` from `.env` |
| `docker login harbor.example.com:8443` | Harbor GUI registry | Harbor account from `harbor/harbor-credentials.txt` or a Harbor-created user |

Log in to the lightweight API registry:

```bash
registry login
# Equivalent explicit Docker command:
docker login registry.example.com
```

Log in to Harbor separately:

```bash
docker login harbor.example.com:8443
```

Harbor’s self-signed lab certificate must be trusted by Docker before this command. For production, use a trusted certificate. Logging out is also separate:

```bash
registry logout
docker logout harbor.example.com:8443
```

Image references must include the registry that contains the image:

```bash
docker pull registry.example.com/team/app:v1
docker pull harbor.example.com:8443/team/app:v1
```

`registry login` never logs in to Harbor, and Harbor login never logs in to the lightweight API registry.

List source images in [`images.txt`](images.txt). Use one image per line; comments and blank lines are ignored:

```text
docker.io/library/nginx:1.27
quay.io/example/application:v1.0.0 my-team/application:v1.0.0
```

Run without arguments for an interactive image prompt:

```bash
./scripts/push-images.sh
```

You can also push one image directly or process a batch file:

```bash
./scripts/push-images.sh nginx:1.27
./scripts/push-images.sh quay.io/example/application:v1.0.0 my-team/application:v1.0.0
./scripts/push-images.sh --file images.txt
```

The script pulls each source image, tags it under `REGISTRY_HOST`, and pushes it. It prints the final private image reference and stops on the first error.

## Kubernetes usage

Create a pull secret in the namespace where the images will run:

```bash
set -a
source .env
set +a
kubectl create secret docker-registry private-registry \
  --docker-server="$REGISTRY_HOST" \
  --docker-username="$REGISTRY_USERNAME" \
  --docker-password="$REGISTRY_PASSWORD"
```

Reference a pushed image in a workload:

```yaml
image: registry.example.com/my-team/application:v1.0.0
imagePullSecrets:
  - name: private-registry
```

## Operations

```bash
./scripts/registry.sh status
./scripts/registry.sh logs
./scripts/registry.sh restart
./scripts/registry.sh down
```

Registry data is stored in the Docker volume `private-docker-registry-data`. `down` stops the service but does not remove image data. Do not run `docker compose down -v` unless you intentionally want to delete all stored images.

## Script reference

| Script | Purpose | Safety behavior |
| --- | --- | --- |
| `scripts/registry.sh` | Unified registry administration CLI: lifecycle, doctor, repositories, images, backups, users, storage, TLS, monitoring, and maintenance | Read-only by default; destructive operations require explicit confirmation |
| `scripts/install.sh` | Interactive API-only or protected side-by-side Harbor GUI installation | Harbor mode uses separate data/ports when an existing registry is detected and never migrates or deletes existing data |
| `scripts/uninstall.sh` | Stop/remove API-only, Harbor, or both deployments | Preserves data by default; permanent removal requires `--purge-data --confirm` |
| `scripts/push-images.sh` | Interactively push one image, push from arguments, or process an image list | Prints the destination reference and stops on the first failed image |
| `scripts/backup-registry.sh` | Archive the registry volume and generate a SHA-256 checksum | Reads the volume without deleting or changing data |
| `scripts/backup-schedule.sh` | Install, inspect, or remove the local cron backup schedule | Schedule removal requires `--confirm`; existing backups are preserved |
| `scripts/restore-registry.sh` | Verify and restore a backup archive | Requires `--confirm`, a stopped registry, a valid checksum, and an empty target volume by default |
| `scripts/migrate-registry.sh` | Copy configuration and checksummed registry data to another VPS over SSH/SCP | Requires the source registry to be stopped and refuses a non-empty destination volume |
| `scripts/migrate-registries.sh` | Copy repositories and tags between the lightweight API registry and Harbor | Copy-only, preserves multi-architecture indexes, verifies digests, and never deletes source data |
| `scripts/retention.sh` | Report or delete old image manifests, including multi-platform indexes | Dry-run by default; deletion requires `--delete --confirm` and skips shared digests |
| `scripts/garbage-collect.sh` | Find or remove unreferenced registry blobs | Requires the registry to be stopped; deletion requires `--delete --confirm` |
| `scripts/firewall.sh` | Configure UFW for verified SSH ports plus HTTP/HTTPS | Dry-run by default and aborts when no SSH port can be verified |
| `scripts/sign-image.sh` | Sign an image with Cosign | Uses `COSIGN_KEY` when set; otherwise uses keyless signing |
| `scripts/verify-image.sh` | Verify a Cosign image signature | Uses `COSIGN_PUBLIC_KEY` when set |
| `scripts/install-aliases.sh` | Install interactive Bash or Zsh aliases | Appends one marked block and preserves existing shell configuration |

## Unified registry command

The `registry` alias is a single CLI for common administration tasks. It accepts `--env-file FILE` before the command when another configuration is required:

```bash
registry doctor
registry version
registry config validate
registry health
registry logs --tail 100
registry logs --follow
registry repo list
registry repo list --json
registry repo tags docker.io/library/nginx
registry image list
registry image inspect docker.io/library/nginx:1.27
registry image exists docker.io/library/nginx:1.27
registry image digest docker.io/library/nginx:1.27
registry image size docker.io/library/nginx:1.27
registry image pull registry.example.com/docker.io/library/nginx:1.27
registry image push
registry image push nginx:1.27 team/nginx:1.27
registry image push --file images.txt
registry image copy source/image:v1 team/image:v1
registry image delete team/application:v1 --confirm
# Only when you intentionally want to remove a digest shared by multiple tags:
registry image delete team/application:v1 --confirm --force-shared
```

Backup, user, storage, TLS, monitoring, and maintenance commands are grouped consistently:

```bash
registry backup create
registry backup list
registry backup verify backups/registry-YYYYMMDDTHHMMSSZ.tar.gz
registry backup restore backups/registry-YYYYMMDDTHHMMSSZ.tar.gz --confirm
registry backup schedule status
registry backup schedule install
registry backup schedule remove --confirm

registry user list
registry user add developer
registry user password developer
registry user remove developer --confirm

registry login                         # Lightweight API registry
registry logout                        # Lightweight API registry
docker login harbor.example.com:8443   # Harbor GUI registry
docker logout harbor.example.com:8443

registry migrate check user@new-vps
registry migrate plan user@new-vps /opt/Private-Docker-Registry
registry migrate run user@new-vps /opt/Private-Docker-Registry --confirm
registry migrate verify user@new-vps /opt/Private-Docker-Registry

registry storage status
registry storage usage
registry storage check
registry storage filesystem check
registry storage aws check --env-file .env.aws-s3.example
registry storage linode check --env-file .env.linode-s3.example
registry tls status
registry tls inspect
registry tls expires
registry tls trust install
registry tls self-signed renew --confirm
registry monitoring status
registry metrics status
registry metrics show
registry firewall check
registry firewall plan
registry firewall apply --confirm
registry gc
registry gc plan
registry gc run --confirm
registry retention plan my-team/application --days 90
registry retention apply my-team/application --days 90 --confirm
registry image sign team/application:v1
registry image verify team/application:v1
```

`registry doctor` checks Docker, Compose configuration, DNS, the configured registry port, TLS files, authentication, the registry volume, free local disk space, and authenticated/unauthenticated API connectivity. S3 checks validate the Compose profile and endpoint reachability without uploading a permanent test object. Firewall checks are dry-run by default and verify active/configured SSH ports before any apply operation.

Read-only operations are the default. Image deletion, user removal, restore overlays, migration runs, TLS renewal, retention deletion, firewall changes, and garbage collection require explicit confirmation flags. If an image digest is shared by multiple tags, image deletion additionally requires `--force-shared`; deleting a manifest does not immediately reclaim blobs until garbage collection runs while the registry is stopped. Basic authentication applies to the whole registry and cannot provide repository-level permissions; use Harbor or an external token service for detailed RBAC.

Global options may be placed before the command: `--env-file FILE`, `--registry HOST`, `--json`, `--quiet`, `--dry-run`, `--confirm`, and `--help`. Some subcommands also accept their confirmation or dry-run flags after the resource arguments for readability. The `registry` alias is intended for interactive administration; scripts and systemd should call the project scripts directly.

### Login troubleshooting after logout

The login helper reads `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` from `.env`. Those values must match the users in `registry/auth/htpasswd`. If the password was changed only in one place, Docker may first report an HTTPS `401 Unauthorized` and then show a misleading fallback error such as `http://registry.example.com/v2/` on port `80`.

Verify the endpoint and authentication without printing the password:

```bash
grep -E '^(REGISTRY_HOST|REGISTRY_PORT|REGISTRY_USERNAME)=' .env
curl -kI https://registry.example.com/v2/
registry logout
registry login
registry health
```

The unauthenticated `curl` request should return `401`; `registry login` should then succeed with the `.env` credentials. If the password must be changed, update the registry account interactively and then update the matching `.env` value before logging in again:

```bash
registry user password registry-admin
# Edit .env and set REGISTRY_PASSWORD to the same new password.
registry restart
registry logout
registry login
```

Never put a password directly on a command line or commit `.env` or `registry/auth/htpasswd` to Git.

## Optional shell aliases

Aliases are convenient for interactive terminal use. They are not required by the scripts and should not be used as dependencies for systemd or automation. Install them explicitly; the installer appends a marked block once and preserves existing shell configuration:

```bash
./scripts/install-aliases.sh
```

For manual installation, add the following to `~/.bashrc`, adjusting `REGISTRY_DIR` if the repository is installed elsewhere:

```bash
export REGISTRY_DIR=/opt/Private-Docker-Registry
alias registry='"$REGISTRY_DIR/scripts/registry.sh"'
alias registry-push='"$REGISTRY_DIR/scripts/push-images.sh"'
alias registry-backup='"$REGISTRY_DIR/scripts/backup-registry.sh"'
```

Reload the shell configuration:

```bash
source ~/.bashrc
```

Example usage from any directory:

```bash
registry status
registry login
registry-push
registry-push nginx:1.27
registry-push /home/user/images.txt
registry-backup
```

## Backups and VPS migration

Create a compressed backup of the registry volume. The backup is created locally and is not committed to Git:

```bash
./scripts/backup-registry.sh
```

For the most consistent backup, stop the registry first with `./scripts/registry.sh down`. Restore only onto a stopped registry and confirm explicitly:

```bash
./scripts/restore-registry.sh backups/registry-YYYYMMDDTHHMMSSZ.tar.gz --confirm
```

Every new backup includes a `.sha256` checksum that restore verifies before extracting. Restore refuses a non-empty target volume. If you intentionally need to overlay a backup without deleting existing files, add `--force-nonempty`; using a new empty volume is safer.

For a legacy backup created before checksum support, create the required sidecar file from its directory:

```bash
sha256sum registry-OLD.tar.gz > registry-OLD.tar.gz.sha256
```

To copy the data, credentials, and certificates to a VPS where this repository is already cloned:

```bash
./scripts/registry.sh down
./scripts/migrate-registry.sh user@new-vps /opt/Private-Docker-Registry
```

The migration script does not delete remote files. It copies `.env`, authentication/certificate files, and registry data, then you start the registry on the VPS:

```bash
cd /opt/Private-Docker-Registry
./scripts/registry.sh up
```

Protect backup archives because they contain image data. Protect `.env`, `registry/auth/`, and `registry/certs/` as secrets.

### Bidirectional API-registry and Harbor migration

The API registry and Harbor have independent storage and user databases. Use the dedicated migration script when copying images in either direction. It requires `skopeo`; the script uses `--all` so multi-architecture indexes are preserved, and it verifies the source and destination digest for every tag.

First create and verify an API-registry backup, then test restoration into a separate temporary volume:

```bash
sudo ./scripts/migrate-registries.sh backup
sudo ./scripts/migrate-registries.sh restore-test \
  backups/registry-YYYYMMDDTHHMMSSZ.tar.gz
```

Run read-only preflight checks and plans in both directions:

```bash
sudo ./scripts/migrate-registries.sh doctor --source api --destination harbor
sudo ./scripts/migrate-registries.sh doctor --source harbor --destination api
sudo ./scripts/migrate-registries.sh plan --source api --destination harbor
sudo ./scripts/migrate-registries.sh plan --source harbor --destination api
```

After reviewing the plans, run a copy. `--confirm` is required, but it does not authorize deletion: migration only creates or updates destination manifests and never deletes source images, users, volumes, or containers.

```bash
sudo ./scripts/migrate-registries.sh run \
  --source api --destination harbor --confirm

sudo ./scripts/migrate-registries.sh run \
  --source harbor --destination api --confirm
```

The migration script does not copy users. Basic-auth users must be recreated in Harbor, or both registries must be connected to the same LDAP/OIDC provider. Do not restore a backup over the live registry after a successful image copy; the source registry was never modified. If a disaster recovery restore is required, stop the API registry and use the separately guarded `scripts/restore-registry.sh` command with a verified backup.

#### Updating an existing private registry from Harbor

Use this workflow when Harbor is the source of newer images and the lightweight private registry must be updated:

```bash
# 1. Back up the lightweight registry before changing its contents.
sudo ./scripts/migrate-registries.sh backup

# 2. Test the backup without touching the live registry.
sudo ./scripts/migrate-registries.sh restore-test \
  backups/registry-YYYYMMDDTHHMMSSZ.tar.gz

# 3. Check connectivity and preview the 1-way copy.
sudo ./scripts/migrate-registries.sh doctor --source harbor --destination api
sudo ./scripts/migrate-registries.sh plan --source harbor --destination api

# 4. Copy and verify every Harbor repository and tag into the API registry.
sudo ./scripts/migrate-registries.sh run \
  --source harbor --destination api --confirm
```

Use the reverse workflow when the API registry is the source of newer images:

```bash
sudo ./scripts/migrate-registries.sh backup
sudo ./scripts/migrate-registries.sh restore-test \
  backups/registry-YYYYMMDDTHHMMSSZ.tar.gz
sudo ./scripts/migrate-registries.sh doctor --source api --destination harbor
sudo ./scripts/migrate-registries.sh plan --source api --destination harbor
sudo ./scripts/migrate-registries.sh run \
  --source api --destination harbor --confirm
```

This is a copy/update operation, not a full bidirectional synchronization: existing destination tags are updated when copied, but tags that exist only on the destination are not deleted. Users, Harbor projects, RBAC, and registry configuration are not synchronized. After migration, verify important image digests and update Docker/Kubernetes image references if the destination hostname changes.

If an API-registry update must be rolled back, stop the API registry first and restore the verified backup. Do not restore during normal migration, because migration does not modify the source registry:

```bash
sudo ./scripts/registry.sh down
sudo ./scripts/restore-registry.sh \
  backups/registry-YYYYMMDDTHHMMSSZ.tar.gz --confirm
sudo ./scripts/registry.sh up
sudo ./scripts/registry.sh health
```

For automatic daily backups on a systemd VPS, update the installation path in `deploy/registry-backup.service`, then install and enable the timer:

```bash
sudo cp deploy/registry-backup.service /etc/systemd/system/
sudo cp deploy/registry-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now registry-backup.timer
systemctl list-timers registry-backup.timer
```

Backups are written to the repository's `backups/` directory. Add off-host storage or a scheduled upload for disaster recovery; a backup on the same VPS does not protect against VPS loss.

## Amazon S3 storage

The default backend is a local Docker volume. To use Amazon S3, create the bucket first, copy the environment example, and enter an IAM access key limited to that bucket:

```bash
cp .env.aws-s3.example .env.aws-s3
chmod 600 .env.aws-s3
# Edit .env.aws-s3 before continuing.
docker compose --env-file .env.aws-s3 \
  -f docker-compose.yml -f docker-compose.aws-s3.yml up -d
```

Do not set a custom endpoint for native Amazon S3. The registry uses AWS Signature Version 4, TLS, server-side encryption by default, and the `/registry` key prefix.

## Linode Object Storage

Create the bucket and access key in Akamai Cloud Manager. Copy the exact S3 endpoint hostname shown for the bucket and prepend `https://`, for example `https://us-east-1.linodeobjects.com`:

```bash
cp .env.linode-s3.example .env.linode-s3
chmod 600 .env.linode-s3
# Edit .env.linode-s3 before continuing.
docker compose --env-file .env.linode-s3 \
  -f docker-compose.yml -f docker-compose.linode-s3.yml up -d
```

The Linode profile enables TLS, Signature Version 4, and path-style requests as required by Registry 3 custom S3 endpoints. Do not switch storage backends while the registry is writing. Existing filesystem data is not copied automatically; migrate it with an appropriate S3 synchronization process while the registry is stopped.

## Cleanup and retention

Run a dry-run retention report for one repository. This example lists manifests whose image build timestamp is older than 90 days, including multi-platform indexes:

```bash
./scripts/retention.sh my-team/application 90
```

Deletion requires both flags. The script skips deletion when multiple tags share one digest:

```bash
./scripts/retention.sh my-team/application 90 --delete --confirm
```

Garbage collection must run while the registry is stopped. The default is a dry run; deletion is explicit:

```bash
./scripts/registry.sh down
./scripts/garbage-collect.sh
./scripts/garbage-collect.sh --delete --confirm
./scripts/registry.sh up
```

## TLS, reverse proxy, and firewall

For production, use the optional Caddy deployment for a trusted Let's Encrypt certificate. Caddy generates and renews the certificate automatically; do not run `openssl req` to create the production certificate. Before starting it:

- Use a publicly resolvable DNS `A`/`AAAA` record for `REGISTRY_HOST`; `/etc/hosts` entries are not sufficient for ACME validation.
- Point the record to this VPS and ensure ports 80 and 443 are reachable from the public internet.
- Stop the direct registry deployment first because both deployments use host port 443.
- Keep the Caddy data volume; it stores the ACME account and certificate state used for automatic renewal.

Set the real public hostname in `.env`, then run the following sequence:

```bash
SSH_PORTS=22 ./scripts/firewall.sh
SSH_PORTS=22 sudo -E ./scripts/firewall.sh --apply
./scripts/registry.sh down
docker compose --env-file .env -f deploy/docker-compose.caddy.yml up -d
```

Replace `22` with every verified SSH port used by the VPS. Caddy requests the certificate after startup and stores the ACME account and certificate data in the persistent `caddy-data` volume. Check certificate issuance and renewal logs with:

```bash
docker compose --env-file .env -f deploy/docker-compose.caddy.yml ps
docker logs private-registry-caddy
registry doctor
printf '\n' | openssl s_client -connect registry.example.com:443 -servername registry.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

The `openssl s_client` command only verifies the certificate currently served by Caddy; it does not generate a certificate. If issuance fails, confirm public DNS resolution and inspect `docker logs private-registry-caddy`. Do not remove the Caddy data volume, because deleting it removes the stored ACME state and certificate cache.

With Caddy active, clients use the normal public URL and do not need the self-signed CA copied into `/etc/docker/certs.d/`. The CLI automatically uses the system trust store when the Caddy container is detected. `registry tls status` continues to inspect the local direct-registry certificate; use the live `openssl s_client` check above to inspect the certificate currently served by Caddy. If you use another public reverse proxy, leave `REGISTRY_CA_FILE` unset; for the direct self-signed deployment, set it to `registry/certs/registry.crt`.

Run `./scripts/firewall.sh` without `--apply` to review the detected ports first. The script reads every effective port from `sshd -T`, preserves the active SSH session port, and adds those allow rules before enabling a deny-by-default incoming policy. It aborts if no SSH port can be verified. Override detection when necessary with `SSH_PORTS="2222,2200" sudo -E ./scripts/firewall.sh --apply`. The Caddy file is a production alternative to the direct-443 setup, not an override to layer on top of it. Stop the direct registry first, then start the Caddy stack. Both stacks use the same persistent volume.

## Monitoring and image signing

The registry exposes an internal Prometheus metrics endpoint. Start the optional Prometheus service with:

```bash
docker compose --env-file .env \
  -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

Prometheus is available only on `127.0.0.1:9090` by default. Use an SSH tunnel or an authenticated reverse proxy for remote access. The registry has a Docker health check backed by its storage-driver health endpoint; check it with `docker inspect private-docker-registry --format '{{.State.Health.Status}}'`.

For supply-chain protection, install [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/) and sign/verify images:

```bash
./scripts/sign-image.sh registry.example.com/my-team/application:v1.0.0
./scripts/verify-image.sh registry.example.com/my-team/application:v1.0.0
```

Set `COSIGN_KEY` and `COSIGN_PUBLIC_KEY` for key-based signing, or use Cosign's keyless OIDC flow.

## GitHub and security

- Never commit `.env`, `registry/auth/`, `registry/certs/`, private keys, or registry data.
- `.gitignore` already excludes local credentials and generated certificates.
- Use a trusted TLS certificate and a firewall/private network for production.
- Keep registry credentials in a secret manager where possible.
- Registry, Caddy, Prometheus, and maintenance helper images are pinned to tested versions; review and test upgrades regularly.
- Replace every `registry.example.com` placeholder with your own hostname only in local deployment files; keep the example values in GitHub generic.
