# POC Kargo + Argo Workflows — Excalidraw (cluster existant)

Promotion d'Excalidraw entre trois namespaces : `excalidraw-dev` → `excalidraw-staging` →
`excalidraw-prod`, sur un cluster qui a **déjà** cert-manager, Argo CD et Traefik (Gateway API).

Ce dossier installe **Kargo** et **Argo Workflows** et crée le pipeline :

```
dev      [deploy]                                                 auto
staging  [precheck] ─► [deploy]                                   auto, si vérifiée en dev
prod     [precheck] ─► [approval] ─► [deploy] ─► [release-record] manuel, après 5 min en staging
```

- `deploy` : étapes natives Kargo (rendu Helm → commit sur `stage/<env>` → sync Argo CD).
- `precheck`, `approval`, `release-record` : WorkflowTemplates Argo Workflows, appelés par
  Kargo (Kargo open source n'a pas l'approbation ni les custom steps natifs).
- Aucune image construite : images officielles `excalidraw/excalidraw`,
  `nginxinc/nginx-unprivileged`, `curlimages/curl`. Compatible PSA `restricted`.

Durée : environ 30 min.

## Contenu

```
config.env.example   Valeurs propres à ton environnement (à copier en config.env)
configure.sh         Renseigne les placeholders __XXX__ à partir de config.env
install/             Values Helm : Kargo, Argo Workflows, Argo Rollouts
exposure/            HTTPRoutes de Kargo et Argo Workflows + authentification basique Traefik
argo-workflows/      Porte d'approbation et custom steps (WorkflowTemplates) + RBAC
argocd/              AppProject + 3 Applications (une par environnement)
kargo/               Projet, Warehouse, tâches de promotion, vérification, stages
charts/excalidraw/   Chart de l'application (avec sa HTTPRoute)
env/<env>/           Values propres à chaque environnement
```

## Ce qui est fixe (ne pas changer sans adapter les manifests)

| Élément | Valeur |
|---|---|
| Kargo | release `kargo`, namespace `kargo` |
| Argo Workflows | release `argo-workflows`, namespace `argo` (Kargo l'appelle sur `http://argo-workflows-server.argo.svc:2746`) |
| Projet Kargo | `excalidraw-poc` |
| Workflows de promotion | namespace `excalidraw-gates` |
| Application | namespaces `excalidraw-dev`, `excalidraw-staging`, `excalidraw-prod` |

---

## Étape 0 — Prérequis

Sur ton poste : `kubectl` (contexte sur le bon cluster), `helm` ≥ 3.8, `git`, `openssl`,
`htpasswd` (paquet `apache2-utils` ou `httpd-tools`), `bash` et `perl` (Git Bash sous Windows).

Vérifier le cluster :

```bash
kubectl get pods -n cert-manager                    # cert-manager présent
kubectl get pods -n argocd                          # Argo CD présent (adapter le namespace)
kubectl get gatewayclass                            # ex. traefik, ACCEPTED True
kubectl get gateway -A                              # la Gateway à utiliser
kubectl get crd middlewares.traefik.io              # CRD Traefik (authentification basique)
kubectl get crd analysistemplates.argoproj.io       # Argo Rollouts : si présent, sauter l'étape 3
```

Sur la Gateway retenue, vérifier le listener :

```bash
kubectl get gateway <nom> -n <ns> -o yaml | grep -A8 'listeners:'
```

- `hostname` absent, ou compatible avec `*.<APPS_DOMAIN>` ;
- `allowedRoutes.namespaces.from: All` (les routes sont créées dans `kargo`, `argo` et
  `excalidraw-*`). Sinon, un `selector` qui accepte ces namespaces.

Et enfin :
- un **DNS wildcard** `*.<APPS_DOMAIN>` qui pointe vers l'adresse de la Gateway ;
- un **dépôt Git** où tu peux pousser, et un identifiant que Kargo utilisera **en écriture** :
  jeton HTTPS (GitHub *fine-grained*, *Contents : Read and write* sur ce seul dépôt) ou
  deploy key SSH avec accès en écriture.

## Étape 1 — Renseigner ton environnement

Copier ce dossier dans ton dépôt GitOps (à la racine ou dans un sous-dossier), puis :

```bash
cd <ton-depot>/<ce-dossier>
cp config.env.example config.env
# éditer config.env : GITOPS_REPO, APP_PATH, APPS_DOMAIN, GATEWAY_*, ARGOCD_NAMESPACE
./configure.sh
```

✅ `OK : tous les placeholders sont renseignés.`
❌ `config.env : X est vide` → compléter `config.env`.

`APP_PATH` est le chemin de ce dossier **dans le dépôt** (`.` s'il est à la racine).

## Étape 2 — Pousser et créer les branches de sortie

```bash
git add -A
git status --short | grep config.env      # doit être VIDE (ignoré par .gitignore)
git commit -m "POC Kargo Excalidraw"
git push origin main

# Une branche par environnement : Kargo y écrira les manifests rendus
for env in dev staging prod; do
  git checkout --orphan "stage/$env"
  git rm -rq --cached .
  echo "# Manifests rendus par Kargo pour $env" > STAGE.md
  git add STAGE.md && git commit -qm "init stage/$env"
  git push -u origin "stage/$env"
  rm STAGE.md && git checkout -qf main
done
```

✅ `main`, `stage/dev`, `stage/staging`, `stage/prod` visibles sur le dépôt distant.

> La branche par défaut doit s'appeler `main`. Sinon, remplacer `branch: main` dans
> `kargo/01-warehouse.yaml`.

## Étape 3 — Installer Argo Rollouts (si absent)

Kargo s'en sert uniquement pour le format de ses vérifications (`AnalysisTemplate`).

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argo-rollouts argo/argo-rollouts --version 2.43.8 \
  -n argo-rollouts --create-namespace -f install/values-argo-rollouts.yaml --wait
kubectl get crd analysistemplates.argoproj.io
```

## Étape 4 — Installer Kargo

```bash
KARGO_ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -d "=+/" | head -c 24)
KARGO_PASSWORD_HASH=$(htpasswd -bnBC 10 "" "$KARGO_ADMIN_PASSWORD" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
echo "Mot de passe admin Kargo : $KARGO_ADMIN_PASSWORD"          # NOTE-LE

helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.4 \
  -n kargo --create-namespace \
  -f install/values-kargo.yaml \
  --set api.adminAccount.passwordHash="$KARGO_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --wait --timeout 10m
kubectl get pods -n kargo
```

✅ Cinq pods `kargo-*` en `Running`.

## Étape 5 — Installer Argo Workflows

```bash
kubectl create namespace excalidraw-gates     # AVANT l'installation (RBAC des workflows)
helm upgrade --install argo-workflows argo/argo-workflows --version 2.0.13 \
  -n argo --create-namespace -f install/values-argo-workflows.yaml --wait
kubectl apply -f argo-workflows/
kubectl get pods -n argo
kubectl get workflowtemplates -n excalidraw-gates
```

✅ `argo-workflows-server` et `argo-workflows-workflow-controller` `Running` ; trois templates
(`approval-gate`, `custom-precheck`, `custom-release-record`).

## Étape 6 — Exposer Kargo et Argo Workflows

Argo Workflows n'a pas d'authentification propre : son interface est protégée par un
identifiant demandé par Traefik.

```bash
WF_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | head -c 20)
echo "Argo Workflows : admin / $WF_PASSWORD"                      # NOTE-LE
kubectl -n argo create secret generic workflows-basic-auth \
  --from-literal=users="$(htpasswd -nbB admin "$WF_PASSWORD")"

kubectl apply -f exposure/
kubectl get httproute -n kargo kargo -o jsonpath='{.status.parents[0].conditions[*].status}'; echo
kubectl get httproute -n argo argo-workflows -o jsonpath='{.status.parents[0].conditions[*].status}'; echo
```

✅ `True True` pour chaque route. Puis, dans le navigateur :
- `http(s)://kargo.<APPS_DOMAIN>` → page de connexion Kargo ;
- `http(s)://workflows.<APPS_DOMAIN>` → identifiant demandé, puis l'UI Argo Workflows.

❌ Route `Accepted False` → le listener n'accepte pas ce namespace ou ce hostname (étape 0).
❌ `404` → DNS ou hostname : `kubectl get httproute -A`.

## Étape 7 — Donner à Kargo et Argo CD l'accès au dépôt

Les mêmes identifiants servent aux deux (Argo CD n'a besoin que de la lecture).
Le projet Kargo est créé d'abord : c'est lui qui crée le namespace `excalidraw-poc`.

```bash
source ./config.env                                          # GITOPS_REPO, ARGOCD_NAMESPACE
kubectl apply -f kargo/00-project.yaml
until kubectl get namespace excalidraw-poc >/dev/null 2>&1; do sleep 2; done
```

**Jeton HTTPS** :

```bash
read -rs GIT_TOKEN                                           # jeton, saisi sans écho
kubectl -n excalidraw-poc create secret generic gitops-repo-creds \
  --from-literal=repoURL="$GITOPS_REPO" --from-literal=username=kargo --from-literal=password="$GIT_TOKEN"
kubectl -n excalidraw-poc label secret gitops-repo-creds kargo.akuity.io/cred-type=git
kubectl -n "$ARGOCD_NAMESPACE" create secret generic excalidraw-poc-repo \
  --from-literal=type=git --from-literal=url="$GITOPS_REPO" \
  --from-literal=username=kargo --from-literal=password="$GIT_TOKEN"
kubectl -n "$ARGOCD_NAMESPACE" label secret excalidraw-poc-repo argocd.argoproj.io/secret-type=repository
```

**Ou deploy key SSH** (`GITOPS_REPO` en `git@…`) : remplacer les `--from-literal=username/password`
par `--from-file=sshPrivateKey=<chemin de la clé privée>` dans les deux secrets.

## Étape 8 — Créer les Applications Argo CD

```bash
source ./config.env
kubectl apply -f argocd/applications.yaml
kubectl get applications -n "$ARGOCD_NAMESPACE" | grep excalidraw
```

✅ `excalidraw-dev`, `excalidraw-staging`, `excalidraw-prod`. Vides tant que Kargo n'a rien
écrit dans `stage/*` : `OutOfSync` ou `Synced` sans ressource est normal.

## Étape 9 — Créer le pipeline Kargo

```bash
kubectl apply -f kargo/
kubectl get warehouse,stages,promotiontasks -n excalidraw-poc
```

✅ Warehouse `excalidraw`, Stages `dev`, `staging`, `prod`, quatre PromotionTasks.

## Étape 10 — Première version : dev puis staging, automatiquement

```bash
kubectl annotate warehouse excalidraw -n excalidraw-poc kargo.akuity.io/refresh="$(date +%s)" --overwrite
kubectl get freight -n excalidraw-poc -L kargo.akuity.io/alias
```

En 2 à 3 minutes :

```bash
kubectl get promotions -n excalidraw-poc -o custom-columns=STAGE:.spec.stage,PHASE:.status.phase
kubectl get workflows -n excalidraw-gates
```

✅ Promotions `dev` puis `staging` en `Succeeded` ; workflow `custom-precheck-staging-…` en
`Succeeded`. L'application répond sur `excalidraw-dev.<APPS_DOMAIN>` et
`excalidraw-staging.<APPS_DOMAIN>`.

## Étape 11 — Promotion en prod avec approbation

Attendre **5 min** après la vérification en staging (sinon la Freight n'est pas proposée).

**Kargo** (`kargo.<APPS_DOMAIN>`, `admin` / mot de passe de l'étape 4), projet `excalidraw-poc` :
1. Icône **camion** du nœud `prod` > **Promote** > **Select** sur la Freight > **Promote**.
2. La pile s'affiche : `precheck` ✅ puis `approval` **Running** (la promotion attend).

**Argo Workflows** (`workflows.<APPS_DOMAIN>/workflows/excalidraw-gates`, `admin` / `WF_PASSWORD`) :
3. Ouvrir `approval-prod-xxxxx`, cliquer sur le nœud **`approval`**, puis **RESUME**.
4. `approve` = **YES**, `approver` = ton nom, `comment` = un mot > valider.
   ⚠️ La valeur par défaut est **NO** : valider sans la changer **refuse** la promotion.

**Retour dans Kargo** (sous 20 s) : `deploy` ✅ puis `release-record` ✅.

```bash
kubectl get pods -n excalidraw-prod                                   # 2 pods Running
kubectl get cm -n excalidraw-gates -l poc/release-record=true         # trace de mise en prod
```

## Étape 12 — Rejouer la démo

La prod a déjà la seule Freight : pour une nouvelle promotion, il faut une **nouvelle Freight**.
Tout commit dans `charts/` ou `env/` en crée une :

```bash
sed -i 's/^replicaCount: 1/replicaCount: 2/' env/dev/values.yaml
git commit -am "dev : 2 réplicas" && git push
kubectl annotate warehouse excalidraw -n excalidraw-poc kargo.akuity.io/refresh="$(date +%s)" --overwrite
```

| Scénario | Comment | Attendu |
|---|---|---|
| Approbation | Étape 11 avec `YES` | Prod mise à jour, décision tracée |
| Refus | Étape 11 avec `NO` | Promotion `Failed`, **prod inchangée**, `deploy` jamais exécuté |
| Pré-contrôle bloquant | `kubectl scale deploy excalidraw -n excalidraw-staging --replicas=0`, puis promouvoir en prod | `precheck` échoue : aucune approbation demandée. Rétablir : resync de `excalidraw-staging` dans Argo CD |
| Retour arrière | Kargo > `prod` > Promote > l'**ancienne** Freight | Version précédente redéployée, avec les mêmes contrôles |

## Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| Pas de Freight | Limite Docker Hub (`429`) | Voir ci-dessous « Docker Hub » |
| Promotion `Errored`, `git-push` | Identifiant Git sans écriture | Jeton *Contents : write* ou deploy key avec écriture, puis recréer `gitops-repo-creds` |
| `argocd-update` en échec | Mauvais `ARGOCD_NAMESPACE` ou Application absente | `kubectl get applications -n <ns>` ; relancer `configure.sh` sur une copie propre |
| `precheck` / `approval` en échec immédiat | Argo Workflows absent ou mal nommé | Release `argo-workflows` dans `argo` ; `kubectl get workflowtemplates -n excalidraw-gates` |
| Promotion `Errored`, `context deadline exceeded` | Cluster saturé | Relancer : Kargo > stage > Promote sur la même Freight |
| Promotion prod refusée : `Freight is not available` | Moins de 5 min en staging | Attendre |
| Pods refusés `violates PodSecurity` | — | Les securityContexts sont fournis ; vérifier les values modifiées |

Voir la cause d'une promotion :

```bash
kubectl get promotions -n excalidraw-poc \
  -o custom-columns=STAGE:.spec.stage,PHASE:.status.phase,MESSAGE:.status.message
kubectl logs -n kargo deploy/kargo-controller --tail=100
```

**Docker Hub** limite les accès anonymes. Avec un compte gratuit et un *access token* :

```bash
kubectl -n excalidraw-poc create secret generic dockerhub-creds \
  --from-literal=repoURL=docker.io/excalidraw/excalidraw \
  --from-literal=username=<compte> --from-literal=password=<token>
kubectl -n excalidraw-poc label secret dockerhub-creds kargo.akuity.io/cred-type=image
```

## Tout retirer

```bash
source ./config.env
kubectl delete -f kargo/ --ignore-not-found          # supprime aussi le namespace excalidraw-poc
kubectl delete -f argocd/applications.yaml           # supprime les 3 Applications
kubectl delete namespace excalidraw-dev excalidraw-staging excalidraw-prod excalidraw-gates
kubectl delete -f exposure/ --ignore-not-found
helm uninstall argo-workflows -n argo
helm uninstall kargo -n kargo
helm uninstall argo-rollouts -n argo-rollouts        # seulement si installé à l'étape 3
kubectl -n "$ARGOCD_NAMESPACE" delete secret excalidraw-poc-repo
```

Les branches `stage/*` restent dans le dépôt : les supprimer à la main si besoin.

## Limites

- Approbation dans l'UI Argo Workflows (pas dans Kargo) ; `approver` est déclaratif.
- Argo Workflows protégé par un identifiant partagé : cible SSO + RBAC sur le *Resume*.
- Compte admin Kargo unique : le RBAC par rôle demande OIDC.
- Les trois environnements sont dans le même cluster.
