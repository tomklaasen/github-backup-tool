# GitHub Backup Tool

A bash script that backs up all your GitHub repositories (personal and organization) to a local directory.

## Dependencies

- [git](https://git-scm.com/)
- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated via `gh auth login`

## Installation

1. Clone this repository
2. Copy the example config and edit it:
   ```bash
   cp backup.conf.example backup.conf
   ```
3. Edit `backup.conf` to set your backup directory and preferred clone protocol.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `/path/to/backup` | Directory where repos are cloned |
| `CLONE_PROTOCOL` | `https` | `https` or `ssh` |
| `LOG_FILE` | *(empty)* | Path to log file. If empty, output goes to stdout |
| `LOG_MAX_SIZE_KB` | `10240` | Rotate the log when it exceeds this size (KB) |
| `LOG_KEEP` | `5` | Number of rotated log files to keep |

## Usage

```bash
./backup.sh
```

The script will:

1. Fetch all your personal repos and repos from your GitHub organizations
2. Clone new repos into `<BACKUP_DIR>/<repo-name>/`
3. Update existing repos with `git fetch --all` + `git pull`
4. Print a summary of cloned, updated, and failed repos

### Cron example

Set `LOG_FILE` in `backup.conf` and run daily at 2 AM:

```
0 2 * * * /path/to/backup.sh
```

All output is timestamped. When the log file exceeds `LOG_MAX_SIZE_KB`, it is
automatically rotated (e.g. `cron.log` → `cron.log.1` → … → `cron.log.5`).
