#!/bin/sh
# Stand-in for a project's template tool.
env_ok() {
  case "$1" in stage|prod) ;; *) echo "unknown env: $1 (stage, prod)" >&2; exit 2 ;; esac
}
case "$1" in
  list) echo '[{"path":"home/banner.json","changed":true},{"path":"home/list.json","changed":false},{"path":"event/popup.json","changed":true}]' ;;
  sync) echo "synced 3 templates" ;;
  plan) env_ok "$2"; echo "[{\"path\":\"home/banner.json\",\"env\":\"$2\"},{\"path\":\"event/popup.json\",\"env\":\"$2\"}]" ;;
  deploy) env_ok "$2"; echo "pushed 2 templates to $2"; echo "message: $3" ;;
  *) echo "usage: tpl.sh list|sync|plan <env>|deploy <env> <message>" >&2; exit 2 ;;
esac
