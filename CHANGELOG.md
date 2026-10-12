# Changelog

## Unreleased

- Correct the PostgreSQL 18 data-volume mount and require a configured password.
- Bind the development port to localhost and remove benchmark port publishing.
- Compile pgvector with portable CPU flags and use the detected build architecture.
- Validate the PostgreSQL 18 / Debian trixie build contract.
- Make health checks verify the initialized extensions over TCP.
- Fix BM25 ranking direction and batch queue consumption in the benchmark.
- Add SQL assertions and Compose container-recreation persistence tests.
- Require runtime validation before publishing the exact tested image.
- Record component versions and package the bundled components' license files.
- Document existing-volume upgrades and the historical release correction.

## v18.4.1 — historical release correction

The Git tag points to commit `43889438aa38b84add34496588c6ace3fd318b52`.
It contains pgvector, pg_search, PGMQ and zhparser/SCWS, but **does not contain
TimescaleDB**. The original GitHub Release description incorrectly stated that
TimescaleDB had been added. That extension was introduced in the later commit
`ec5e3918161c92a192cfe4cecdc7c9cbc4995e88`.

The historical tag remains unchanged. The image workflow corrects the original
description after the current validation gate passes, provided the historical
tag and original description still match the known values. It does not overwrite
a subsequently edited description or move a published tag.

Use a validated later image and record its digest for deployments. A project
release tag is a bundle version; query `SELECT version()` for the actual
PostgreSQL server version.
