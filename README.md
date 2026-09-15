# xgc2-fs150-tools

Field bring-up scripts for XGC2 **FS150 UAV**.

This repository is public. It does **not** contain site Wi-Fi passwords or private APT URLs.

Pass secrets via:

- flags (`--wifi-ssid`, `--wifi-password`, `--apt-url`, `--site-env`)
- environment (`XGC2_WIFI_SSID`, `XGC2_WIFI_PASSWORD`, `XGC2_APT_BASE_URL`)
- `site.env` in the parent UserScripts directory (private XGC2 station)

The XGC2 product mounts this repo as `user-scripts/FS150/`.
