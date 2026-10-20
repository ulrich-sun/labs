#!/usr/bin/env bash
# Remplace les placeholders __XXX__ des manifests par les valeurs de config.env.
# À lancer UNE fois, depuis ce dossier, avant le premier commit.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f config.env ]; then
  echo "config.env absent : cp config.env.example config.env, puis l'adapter." >&2
  exit 1
fi
# shellcheck disable=SC1091
source ./config.env

for v in GITOPS_REPO APP_PATH APPS_DOMAIN GATEWAY_NAME GATEWAY_NAMESPACE GATEWAY_SECTION ARGOCD_NAMESPACE; do
  if [ -z "${!v:-}" ]; then echo "config.env : $v est vide" >&2; exit 1; fi
done

# "kargo-poc/" -> "kargo-poc" ; "." -> préfixe vide (dossier à la racine du dépôt)
APP_PATH="${APP_PATH%/}"
if [ "$APP_PATH" = "." ]; then APP_PREFIX=""; else APP_PREFIX="$APP_PATH/"; fi

export GITOPS_REPO APP_PATH APP_PREFIX APPS_DOMAIN GATEWAY_NAME GATEWAY_NAMESPACE GATEWAY_SECTION ARGOCD_NAMESPACE

FILES=$(grep -rlE '__(GITOPS_REPO|APP_PATH|APP_PREFIX|APPS_DOMAIN|GATEWAY_NAME|GATEWAY_NAMESPACE|GATEWAY_SECTION|ARGOCD_NAMESPACE)__' \
  argocd argo-workflows charts env exposure install kargo || true)
if [ -z "$FILES" ]; then
  echo "Aucun placeholder trouvé : configure.sh a déjà été lancé."
  exit 0
fi

for f in $FILES; do
  perl -pi -e '
    s/__GITOPS_REPO__/$ENV{GITOPS_REPO}/g;
    s/__APP_PATH__/$ENV{APP_PATH}/g;
    s/__APP_PREFIX__/$ENV{APP_PREFIX}/g;
    s/__APPS_DOMAIN__/$ENV{APPS_DOMAIN}/g;
    s/__GATEWAY_NAMESPACE__/$ENV{GATEWAY_NAMESPACE}/g;
    s/__GATEWAY_NAME__/$ENV{GATEWAY_NAME}/g;
    s/__GATEWAY_SECTION__/$ENV{GATEWAY_SECTION}/g;
    s/__ARGOCD_NAMESPACE__/$ENV{ARGOCD_NAMESPACE}/g;
  ' "$f"
  echo "  configuré : $f"
done

LEFT=$(grep -rnE '__[A-Z_]+__' argocd argo-workflows charts env exposure install kargo || true)
if [ -n "$LEFT" ]; then
  echo "Placeholders restants :" >&2; echo "$LEFT" >&2; exit 1
fi
echo "OK : tous les placeholders sont renseignés."
