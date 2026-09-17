# Celéri public base image

Ubuntu 26.04 LTS with PHP FPM/CLI, Node 24 LTS, nginx, Redis, Horizon's
supervisor definition, Chrome for Testing, and the Highcharts export server.
This repository builds the runtime only; application code and credentials are
supplied by the application image and its environment.

## Build locally

Chrome for Testing is available for Linux amd64, so specify the platform even
when building on an Apple Silicon machine. The final target defaults to PHP
8.5; the PHP 8.3 bridge keeps the existing Laravel 10 application on its current
PHP minor release during the operating-system upgrade.

```sh
docker build --platform linux/amd64 -t celeri/public-base:upgrade-php85 .
docker build --platform linux/amd64 --build-arg PHP_VERSION=8.3 \
  -t celeri/public-base:upgrade-php83 .
```

Both use the same `/run/php/celeri-fpm.sock` socket and
`/usr/local/sbin/celeri-php-fpm` executable link. No nginx or supervisor edit is
needed to switch between them. PHP packages come from the signed
[Sury Resolute repository](https://packages.sury.org/php/), including its PECL
IMAP package for PHP 8.5. Apt packages receive current security updates when the
image is rebuilt; release images should be recorded by immutable digest.

The Dockerfile pins Node 24.21.0, Composer 2.10.3, Puppeteer 25.11.0, Chrome
153.0.8010.36, export server 6.0.0, and Highcharts 13.0.0. Chrome and Puppeteer
follow the [upstream compatibility table](https://pptr.dev/supported-browsers).
Node and Composer downloads are verified against upstream checksums. Change
these build arguments deliberately, then repeat the render checks below and
application report comparisons before releasing an image.

## Runtime behavior

- Supervisor runs PHP FPM, nginx, Redis, Horizon, and the export server. The
  application entrypoint remains responsible for starting cron and registering
  its scheduler entry, as in the existing deployment.
- Horizon runs as `www-data` from the application directory, with its home set
  to application storage. This keeps worker-created files writable by PHP FPM.
- `display_errors` and `display_startup_errors` are off in CLI and FPM; errors
  remain logged. Uploads remain capped at 100 MB, FPM memory at 512 MB, and
  request execution time at 300 seconds. FPM inherits the container environment.
- SOAP, IMAP, APCu, BCMath, GD, Intl, MySQL/PostgreSQL/SQLite PDO drivers, Redis,
  XML, ZIP, and OPcache are validated during the image build. Unused mcrypt is
  removed. The application must still exercise its real SOAP/IMAP integrations
  in an authorized test environment before rollout.
- Chrome uses a fixed executable shared by Puppeteer and Browsershot. The
  export server's browser flags are configured in
  `/etc/highcharts-export-server.json`; the application Dockerfile must remove
  its old `sed` patch against the exporter's installed source.
- The export server binds only to `127.0.0.1:7801`. Highcharts scripts come from
  the pinned npm package, with no CDN fetch or custom remote scripts at runtime.
  National fonts from `fonts/` are installed and indexed with fontconfig.
- MySQL **server**, its bootstrap SQL and data volume are removed. Databases
  come from RDS or an explicitly configured test service. Global Laravel
  installer/Envoy, gulp and bower are also removed.

## Local verification

The build checks required PHP extensions, diagnostic settings, FPM/nginx
configuration and executable versions. The smoke script exercises the
runtime without starting the application, Horizon, Redis, or cron and without
network access. Run them against both image tags.

```sh
docker run --rm --platform linux/amd64 --network none \
  --volume "$PWD/scripts:/checks:ro" --entrypoint bash \
  celeri/public-base:upgrade-php85 /checks/smoke-base.sh
```

These smoke checks do not establish application compatibility or authorize a
push/deployment. The platform upgrade plan requires a successful application
suite, representative PDF/chart comparisons and the normal Dev acceptance
checks before a production release.

## Independent builds and publishing

The `Base image` GitHub Actions workflow builds and smoke-tests PHP 8.3 and 8.5
on amd64. Pushes to `main` or `codex/platform-upgrade-2026`, and pull requests,
run it only when base inputs or its verification files change. It imports and
exports a separate GitHub Actions layer cache for each PHP version. Tool version
arguments are declared near their install layers so later tool updates retain
the preceding OS/PHP cache.

The weekly scheduled run bypasses install caches and pulls the current Ubuntu
image to exercise current OS/PHP packages. Scheduled workflows run from the
repository's default branch; this schedule becomes active when the workflow is
available there. Scheduled, push and pull-request runs **never publish** images.

To publish a tested base intentionally:

1. Configure the base repository secrets `DOCKERHUB_USERNAME` and
   `DOCKERHUB_TOKEN`, with access to push `celeri/public-base`.
2. Dispatch `Base image` manually from the reviewed branch with `publish` set
   to true. Set `refresh` to true when taking current OS/PHP updates rather than
   reusing the installation cache.
3. Each PHP variant must pass the offline smoke checks before its tested image
   is pushed. Tags use `php<version>-<commit>-<run-id>-<attempt>`, so a security
   rebuild of the same source has its own version. No `latest`, `develop` or
   production application tags are moved.
4. Copy the matching `celeri/public-base@sha256:...` reference from the job
   summary into the application's `BASE_IMAGE` configuration. The application
   build consumes that published base; application-only changes do not rebuild
   PHP, Chrome, fonts or the operating system.

This workflow does not deploy the application or change any existing Docker Hub
autobuild rules. If Docker Hub still builds this repository automatically,
disable or reconfigure those external rules separately when choosing GitHub
Actions as the publishing owner; the rules are not stored in this checkout.
