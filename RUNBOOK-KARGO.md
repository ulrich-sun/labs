# Runbook — POC Kargo (Argo CD, Rancher, Azure DevOps)

Promotion d'Excalidraw entre trois **namespaces** d'un même cluster :
`excalidraw-dev` → `excalidraw-staging` → `excalidraw-prod`.
Tout se fait par **commandes**, sans script. cert-manager et Argo CD sont **déjà installés**
sur le cluster : on ne les touche pas.

Chaque étape donne : les commandes, le **résultat attendu** (✅) et quoi faire sinon (❌).
Commandes prévues pour un shell Linux (bash) avec `kubectl` pointé sur le cluster.

## Ce qui sera installé

| Namespace | Contenu |
|---|---|
| `argo-rollouts` | Argo Rollouts : fournit les CRD de vérification utilisées par Kargo |
| `kargo` | Kargo (contrôleurs, API, UI) |
| `argo`, `excalidraw-gates` | Argo Workflows et la porte de mise en prod (Trivy, smoke test, approbation) |
| `excalidraw-poc` | Le projet Kargo (Warehouse, versions, stages) |
| `excalidraw-dev`, `excalidraw-staging`, `excalidraw-prod` | Les trois environnements, créés par Argo CD |

---

## Étape 0 — Vérifier le point de départ

```bash
kubectl config current-context
kubectl auth can-i create namespaces
kubectl auth can-i create customresourcedefinitions
kubectl get crd certificates.cert-manager.io
kubectl get pods -n argocd                      # adapter si Argo CD est dans un autre namespace
kubectl get crd analysistemplates.argoproj.io workflowtemplates.argoproj.io stages.kargo.akuity.io
helm version
```

✅ Le bon contexte ; `yes` deux fois ; le CRD cert-manager existe ; les pods Argo CD sont `Running` ;
la dernière commande répond `NotFound` pour les trois CRD (rien d'installé).
❌ `no` → il faut un compte admin du cluster. ❌ Un des trois CRD existe déjà → Argo Rollouts,
Argo Workflows ou Kargo est déjà installé : sauter l'installation correspondante plus bas.

## Étape 1 — Préparer Azure DevOps et le registre

Dans **Azure DevOps** :
1. *Repos* > *New repository* : dépôt vide, sans README (ex. `promotion-poc-excalidraw`).
2. Copier l'URL HTTPS et **supprimer `<org>@`** : `https://dev.azure.com/<org>/<projet>/_git/<depot>`.
3. *User settings* > *Personal access tokens* > *New token* : scope **Code : Read & write**.

**Registre** : un dépôt d'images où tu peux pousser (ex. Azure Container Registry).

Définir les variables utilisées dans tout le runbook (même terminal jusqu'à la fin) :

```bash
export GITOPS_REPO="https://dev.azure.com/<org>/<projet>/_git/promotion-poc-excalidraw"
export GIT_TOKEN="<PAT Azure DevOps>"
export IMAGE_REPO="<registre>/excalidraw"          # ex. monacr.azurecr.io/excalidraw
export ARGOCD_NS="argocd"                            # namespace de ton Argo CD
```

## Étape 2 — Personnaliser les fichiers

Depuis le dossier `promotion-poc-excalidraw` décompressé :

```bash
cd promotion-poc-excalidraw

grep -rlE '__[A-Z_]+__' app stack-kargo | xargs sed -i \
  -e "s#__GITOPS_REPO__#${GITOPS_REPO}#g" \
  -e "s#__IMAGE_REPO__#${IMAGE_REPO}#g" \
  -e "s#__ARGOCD_NS__#${ARGOCD_NS}#g" \
  -e "s#__DEST_SERVER__#https://kubernetes.default.svc#g" \
  -e "s#__GIT_USERNAME__#kargo#g" \
  -e "s#__GIT_TOKEN__#${GIT_TOKEN}#g" \
  -e "s#__GROUP_DEVS__#excalidraw-devs#g" \
  -e "s#__GROUP_RELEASE__#excalidraw-release-managers#g" \
  -e "s#__DOMAIN__#example.local#g" \
  -e "s#__INGRESS_CLASS__#nginx#g" \
  -e "s#__RANCHER_PROJECT_ID__#c-xxxxx:p-xxxxx#g"

grep -rnE '__[A-Z_]+__' app stack-kargo
```

✅ La dernière commande n'affiche **rien**.
Note : `__DOMAIN__` et `__INGRESS_CLASS__` ne servent que si tu actives l'Ingress optionnel ;
`__GROUP_*__` que si tu branches l'OIDC (démo RBAC).

## Étape 3 — Pousser le dépôt GitOps

```bash
git init -b main
git remote add origin "$GITOPS_REPO"
git add -A
git status --short | grep secrets/          # doit être VIDE : les secrets restent sur ton poste
git commit -m "POC promotion Excalidraw"
git push -u origin main                      # utilisateur : n'importe quoi, mot de passe : le PAT
```

Créer les trois branches d'environnement (vides, Kargo y écrira les manifests rendus) :

```bash
for env in dev staging prod; do
  git checkout --orphan "stage/$env"
  git rm -rq --cached .
  echo "# Manifests rendus par Kargo pour $env" > STAGE.md
  git add STAGE.md
  git commit -qm "init stage/$env"
  git push -u origin "stage/$env"
  rm STAGE.md
  git checkout -qf main
done
git branch -a
```

✅ `git branch -a` liste `main`, `stage/dev`, `stage/staging`, `stage/prod` (en local et `remotes/origin/…`).
Dans Azure DevOps > *Repos* > *Branches*, les quatre branches apparaissent.
❌ `Authentication failed` → PAT expiré ou sans *Code : Read & write*.

## Étape 4 — Installer Argo Rollouts (CRD de vérification)

À sauter si `analysistemplates.argoproj.io` existait à l'étape 0.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace --wait
kubectl get crd analysistemplates.argoproj.io analysisruns.argoproj.io
```

✅ Les deux CRD sont listés. Les applications n'ont **pas** besoin d'utiliser des Rollouts.

## Étape 5 — Installer Kargo

```bash
KARGO_ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
KARGO_PASSWORD_HASH=$(htpasswd -bnBC 10 "" "$KARGO_ADMIN_PASSWORD" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
echo "Mot de passe admin Kargo : $KARGO_ADMIN_PASSWORD"     # NOTE-LE

helm install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.12.3 \
  --namespace kargo --create-namespace \
  --set api.adminAccount.passwordHash="$KARGO_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --set controller.argocd.namespace="$ARGOCD_NS" \
  --wait

kubectl get pods -n kargo
```

✅ Tous les pods `kargo-*` sont `Running`.
❌ `htpasswd: command not found` → paquet `apache2-utils` (Debian/Ubuntu) ou `httpd-tools` (RHEL).
❌ Pods en `ContainerCreating` longtemps → `kubectl describe pod -n kargo <pod>` : souvent un
certificat cert-manager en attente (`kubectl get certificate -n kargo`) ou `ghcr.io` bloqué par le proxy.
❌ Version `1.12.3` introuvable → retirer `--version` (dernière version), puis noter celle installée :
`helm list -n kargo`.

Ouvrir l'UI (laisser tourner dans un second terminal) :

```bash
kubectl port-forward -n kargo svc/kargo-api 8443:443
```

✅ https://localhost:8443 (certificat auto-signé à accepter), connexion **admin** avec le mot de passe noté.

## Étape 6 — Installer Argo Workflows (porte de mise en prod)

```bash
helm repo add argo https://argoproj.github.io/argo-helm   # si pas fait à l'étape 4
helm repo update
kubectl create namespace excalidraw-gates
helm install argo-workflows argo/argo-workflows \
  -n argo --create-namespace \
  -f stack-kargo/argo-workflows/values.yaml \
  --wait
kubectl apply -f stack-kargo/argo-workflows/prod-gate.yaml
kubectl get pods -n argo
kubectl get workflowtemplate -n excalidraw-gates
```

✅ Pods `argo-workflows-server` et `argo-workflows-workflow-controller` `Running` ; le template `prod-gate` existe.

UI (troisième terminal) :

```bash
kubectl port-forward -n argo svc/argo-workflows-server 2746:2746
```

✅ http://localhost:2746 s'ouvre sans login (mode POC, cf. Limites).

## Étape 7 — Brancher Argo CD sur les trois namespaces

```bash
kubectl apply -f stack-kargo/secrets/argocd-repo.yaml       # accès d'Argo CD à Azure Repos
kubectl apply -f stack-kargo/argocd/applications.yaml
kubectl get applications -n "$ARGOCD_NS" | grep excalidraw
```

✅ Trois Applications `excalidraw-dev|staging|prod`, état **OutOfSync** ou **Unknown** : normal,
les branches `stage/*` sont encore vides. Kargo déclenchera leur premier sync.
❌ Message `authentication required` dans l'UI Argo CD → l'URL du secret et celle des Applications
doivent être **identiques** (attention à `org@`).

## Étape 8 — Créer le pipeline Kargo

```bash
kubectl apply -f stack-kargo/kargo/00-project.yaml
until kubectl get namespace excalidraw-poc >/dev/null 2>&1; do sleep 2; done   # Kargo crée le namespace
kubectl apply -f stack-kargo/secrets/kargo-git-credentials.yaml
kubectl apply -f stack-kargo/kargo/
kubectl get warehouse,stages -n excalidraw-poc
```

✅ Un Warehouse `excalidraw` et trois Stages `dev`, `staging`, `prod`. Dans l'UI Kargo, le projet
`excalidraw-poc` affiche le pipeline `dev → staging → prod`.

**Registre privé uniquement** (ex. ACR — créer un token de lecture : *Repository permissions* >
*Tokens*). Les namespaces d'environnement sont créés à l'avance pour y poser le secret :

```bash
export REGISTRY_SERVER="<registre>"            # ex. monacr.azurecr.io
export REGISTRY_USERNAME="<nom-du-token>"
read -rs REGISTRY_PASSWORD; export REGISTRY_PASSWORD

for env in dev staging prod; do
  kubectl create namespace "excalidraw-$env" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "excalidraw-$env" create secret docker-registry registry-pull \
    --docker-server="$REGISTRY_SERVER" --docker-username="$REGISTRY_USERNAME" \
    --docker-password="$REGISTRY_PASSWORD"
done

for ns in excalidraw-poc excalidraw-gates; do
  kubectl -n "$ns" create secret generic registry-creds \
    --from-literal=username="$REGISTRY_USERNAME" --from-literal=password="$REGISTRY_PASSWORD"
done

kubectl -n excalidraw-poc create secret generic excalidraw-image-creds \
  --from-literal=repoURL="$IMAGE_REPO" \
  --from-literal=username="$REGISTRY_USERNAME" --from-literal=password="$REGISTRY_PASSWORD"
kubectl -n excalidraw-poc label secret excalidraw-image-creds kargo.akuity.io/cred-type=image
```

## Étape 9 — Publier la première version

**Option A — depuis ton poste (Docker)** :

```bash
docker login "${IMAGE_REPO%%/*}"
docker pull excalidraw/excalidraw:latest
docker tag excalidraw/excalidraw:latest "$IMAGE_REPO:1.0.0"
docker push "$IMAGE_REPO:1.0.0"
```

**Option B — Azure Pipelines** : *Project settings* > *Service connections* > *Docker Registry*
nommée `excalidraw-registry` ; puis *Pipelines* > *New pipeline* > ce dépôt > *Existing YAML* >
`/shared/azure-pipelines/publish-excalidraw.yml` ; *Run pipeline* avec `version = 1.0.0`.

Forcer Kargo à regarder le registre tout de suite (sinon ≤ 2 min) :

```bash
kubectl annotate warehouse excalidraw -n excalidraw-poc kargo.akuity.io/refresh="$(date +%s)" --overwrite
kubectl get freight -n excalidraw-poc
```

✅ Une Freight apparaît (nom = empreinte, label `kargo.akuity.io/alias` du type `wise-otter`).
Puis, en 5 à 10 minutes, sans rien faire :

```bash
kubectl get promotions -n excalidraw-poc                     # dev puis staging : Succeeded
kubectl get applications -n "$ARGOCD_NS" | grep excalidraw   # dev et staging : Synced / Healthy
kubectl get pods -n excalidraw-dev
kubectl get pods -n excalidraw-staging
```

Voir l'application en dev :

```bash
kubectl port-forward -n excalidraw-dev svc/excalidraw 8081:80     # http://localhost:8081
```

❌ Pas de Freight → `kubectl get warehouse excalidraw -n excalidraw-poc -o yaml` et lire
`status.conditions` : tag non SemVer, ou registre privé sans les secrets de l'étape 8.
❌ Promotion `Failed` → `kubectl get promotion <nom> -n excalidraw-poc -o yaml` et lire `status.message`.

## Étape 10 — Promouvoir en prod (porte d'approbation)

Conditions : la version est vérifiée en staging **depuis 10 min**, et on est **lun–ven entre 9h
et 17h** (heure de Montréal).

1. UI Kargo > stage `prod` > icône camion > *Promote* > choisir la Freight > *Promote*.
2. La promotion reste **Running** : Kargo a lancé la porte de prod.

```bash
kubectl get workflows -n excalidraw-gates
```

3. UI Argo Workflows (http://localhost:2746) > namespace `excalidraw-gates` > `prod-gate-xxxxx` :
   `trivy-scan` et `smoke-staging` sont verts, `approval` est en pause.
4. Clic sur `approval` > **Resume** > `approve = YES`, un commentaire > *Resume*.

✅ Workflow `Succeeded`, promotion Kargo `Succeeded`, puis :

```bash
kubectl get pods -n excalidraw-prod           # 2 pods Running
```

❌ Promotion refusée dès la création → hors fenêtre horaire ou soak de 10 min pas écoulé.
Pour tester hors heures ouvrables : supprimer le bloc `promotionWindows` de
`stack-kargo/kargo/00-project.yaml`, puis `kubectl apply -f stack-kargo/kargo/00-project.yaml`.

---

## Scénarios de démo

| # | Scénario | Commandes / actions | Attendu |
|---|---|---|---|
| 1 | Flux nominal | Publier `1.1.0` (étape 9) | dev puis staging automatiques ; prod disponible après 10 min |
| 2 | Approbation | Étape 10 avec `YES` | Prod mise à jour, décision tracée dans le workflow |
| 3 | Refus | Étape 10 avec `NO` | Workflow et promotion `Failed`, prod inchangée |
| 4 | Version cassée | `docker pull busybox:1.36 && docker tag busybox:1.36 "$IMAGE_REPO:1.2.0" && docker push "$IMAGE_REPO:1.2.0"` (ou pipeline avec `broken = true`) | Pods dev en `CrashLoopBackOff`, vérification `Failed`, staging jamais touché |
| 5 | Rollback auto | UI Kargo : promouvoir de force `1.2.0` en staging (approbation manuelle de la Freight) | Vérification staging `Failed` → Kargo repromeut seul la dernière version stable |
| 6 | Hotfix | UI Kargo : Freight > *Manually Approve* > `prod` | Promotion prod possible sans passer par staging, tracée sur la Freight |
| 7 | Fenêtre de gel | Promouvoir en prod un samedi ou après 17h | Refusé |

## Dépannage — commandes utiles

| Je veux voir… | Commande |
|---|---|
| L'état du Warehouse (détection des versions) | `kubectl get warehouse excalidraw -n excalidraw-poc -o jsonpath='{.status.conditions}'` |
| Les versions détectées | `kubectl get freight -n excalidraw-poc -L kargo.akuity.io/alias` |
| L'état des stages | `kubectl get stages -n excalidraw-poc` |
| Pourquoi une promotion a échoué | `kubectl get promotions -n excalidraw-poc -o custom-columns=NOM:.metadata.name,STAGE:.spec.stage,PHASE:.status.phase,MESSAGE:.status.message` |
| Les vérifications (smoke, Trivy) | `kubectl get analysisruns -n excalidraw-poc` puis `kubectl get jobs -n excalidraw-poc` et `kubectl logs job/<nom> -n excalidraw-poc` |
| L'état côté Argo CD | `kubectl get applications -n "$ARGOCD_NS" -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,SANTE:.status.health.status` |
| Les pods d'un environnement | `kubectl get pods -n excalidraw-<env> -o wide` |
| La porte de prod | `kubectl get workflows -n excalidraw-gates` puis `kubectl describe workflow <nom> -n excalidraw-gates` |
| Les logs Kargo | `kubectl logs -n kargo deploy/kargo-controller --tail=100` |

| Symptôme | Cause probable | Correction |
|---|---|---|
| Pas de Freight | Tag non `x.y.z` ; registre privé | Publier un tag SemVer ; secrets de l'étape 8 |
| `git-push` / `git-clone` en échec | PAT expiré ou scope insuffisant ; `org@` dans l'URL | Nouveau PAT, puis `kubectl apply -f stack-kargo/secrets/kargo-git-credentials.yaml` |
| `argocd-update` refusé | Namespace Argo CD différent | Réinstaller Kargo avec `controller.argocd.namespace` correct (étape 5, `helm upgrade`) |
| Application `ComparisonError` | Argo CD n'accède pas au dépôt | Étape 7, URL identique partout |
| Pods `ImagePullBackOff` | Registre privé | Secrets de l'étape 8 |
| Promotion prod bloquée en `Running` | Approbation en attente | UI Argo Workflows > `approval` > Resume |

## Retour arrière complet

```bash
kubectl delete -f stack-kargo/argocd/applications.yaml
kubectl delete project.kargo.akuity.io excalidraw-poc
kubectl delete namespace excalidraw-dev excalidraw-staging excalidraw-prod excalidraw-gates
kubectl delete -f stack-kargo/secrets/argocd-repo.yaml
helm uninstall argo-workflows -n argo
helm uninstall kargo -n kargo
helm uninstall argo-rollouts -n argo-rollouts      # seulement si installé à l'étape 4
```

cert-manager et Argo CD ne sont pas touchés.

## Limites connues

- L'approbation se fait dans Argo Workflows : **deuxième interface** ; pour deux approbateurs, il
  faut deux étapes `suspend` successives.
- Argo Workflows est installé **sans authentification** (POC) : passer en `authModes: [sso]`
  (Entra ID) + RBAC avant tout usage réel.
- Les trois environnements partagent un cluster : un incident cluster les touche tous.
- Le PAT Azure DevOps est personnel et expire : pour la cible, un compte de service.
- Champs vérifiés sur la doc Kargo v1.12 (oct. 2026) ; Kargo 2.0 est annoncé.
