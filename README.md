# Paperless-ngx Update Script

This repository contains a Bash script for updating a local Paperless-ngx installation on an Ubuntu system with a bare-metal setup under `/opt/paperless`.

## Overview

The script performs the following steps:

- checks whether the required tools are installed
- reads the installed version from the local file `/opt/paperless/src/paperless/version.py`
- shows a graphical dialog with options for update, repair, or abort
- stops the relevant Paperless services
- creates a backup of configuration, database, and media files
- downloads the latest GitHub release
- removes stale files from the previous release tree while preserving data, media, consume, and configuration files
- updates the files in the installation directory
- runs `pip`, `migrate`, `collectstatic`, and other Paperless-related operations
- restarts the services
- shows progress in a live log
- removes temporary files and backup folders

## Requirements

The script was developed for the following environment:

- Ubuntu 24.04 LTS
- Paperless-ngx installation under `/opt/paperless`
- user `paperless`
- Python virtual environment under `/opt/paperless/venv`

Required packages:

- `bash`
- `curl`
- `jq`
- `wget`
- `tar`
- `rsync`
- `dialog`

## Installation

1. Clone the repository or download the file `paperless_update.sh`.
2. Make it executable:

```bash
chmod +x paperless_update.sh
```

3. Run it as root:

```bash
sudo ./paperless_update.sh
```

## Usage Notes

- The script is designed for the structure described here and was developed for this specific installation.
- You should perform your own security review before using it.
- It is advisable to review the script and adjust paths if needed before first use.

## Disclaimer

This script is provided without any warranty. It is provided solely for demonstration and administrative purposes.

I accept no responsibility for any damage, data loss, downtime, or other consequences resulting from the execution of this script on systems or in environments other than my own. Each user is solely responsible for reviewing the script, assessing its security, and taking appropriate precautions for their own system.

## License

This project is licensed under the same license as the repository, unless another license is specified.
