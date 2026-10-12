# myhomecontrol-assets

Scripts, icons and configuration files used in the articles on [myhomecontrol.pl](https://www.myhomecontrol.pl/) - a blog
about building a smart home on Home Assistant, Docker and self-hosted services. The articles are in Polish; each asset
below links to the one that explains how to set it up.

## Scripts

- [`scripts/mariadb-backup`](scripts/mariadb-backup/README.md) – backup (`mariadb_backup.sh`) and restore (`restore_mariadb.sh`) of the Home Assistant MariaDB database running in Docker, with optional signed webhook notifications to my custom notification app.
  Article: [Automatyczna kopia zapasowa MariaDB](https://www.myhomecontrol.pl/ecosystem/mariadb-backup)

## Home Assistant

- [`homeassistant/icons/weather-card`](homeassistant/icons/weather-card) – SVG weather icons for the custom weather card, named after Home Assistant weather conditions.
  Article: [Customowa karta pogody](https://www.myhomecontrol.pl/user-interface/ui-weather-card)
- [`homeassistant/themes/shadcn-sky.yaml`](homeassistant/themes/shadcn-sky.yaml) – "Shadcn Sky" theme based on the shadcn/ui Sky palette, with light and dark modes and custom `--sc-*` tokens for button-card.
  Article: [Własny motyw](https://www.myhomecontrol.pl/user-interface/ui-custom-theme)

## Usage

The articles download files straight from the `main` branch (`raw.githubusercontent.com` or the `tar.gz` archive), so
any change here goes live for readers as soon as it is pushed.

More guides on Home Assistant, dashboards, automations and self-hosting: [myhomecontrol.pl](https://www.myhomecontrol.pl/).
