# shellcheck shell=bash
# config.sh — single source of truth for the ~/.config/tart-stacks/* config-file
# locations. Sourced by the bin/ scripts and script/setup; never on PATH, never
# executable. Per-concern precedence: TART_<CONCERN> > TART_STACKS_CONFIG_DIR >
# $HOME/.config/tart-stacks. The on-disk file formats are the cross-repo contract
# with the producer (workbench) and do NOT live here — only the paths do.

tart_config_dir() { printf '%s' "${TART_STACKS_CONFIG_DIR:-$HOME/.config/tart-stacks}"; }

# tart_config_path <concern> — resolve one of the four config files.
tart_config_path() {
  case "$1" in
    netpolicy)  printf '%s' "${TART_NETPOLICY:-$(tart_config_dir)/netpolicy}" ;;
    mounts)     printf '%s' "${TART_MOUNTS:-$(tart_config_dir)/mounts}" ;;
    forwards)   printf '%s' "${TART_FORWARDS:-$(tart_config_dir)/forwards}" ;;
    ssh-agents) printf '%s' "${TART_SSH_AGENTS:-$(tart_config_dir)/ssh-agents}" ;;
    *) echo "tart_config_path: unknown concern '$1'" >&2; return 2 ;;
  esac
}
