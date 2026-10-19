# POC Kargo — Excalidraw (Argo CD, Rancher, Azure DevOps, JFrog)

Promotion d'Excalidraw entre trois **namespaces** d'un même cluster :
`excalidraw-dev` → `excalidraw-staging` → `excalidraw-prod`.

- **Kargo open source** seulement, sans licence.
- **Aucun build d'image** : on utilise l'image officielle `excalidraw/excalidraw` telle quelle, via JFrog.
- **Pas de scan dans le pipeline** : JFrog Xray s'en charge déjà.
- **Tout se personnalise par fichiers values** (Helm) : application ET outils installés.
- Exposition par **HTTPRoute** (Gateway API), optionnelle.
- cert-manager et Argo CD sont **déjà installés** : on ne les touche pas.
- Uniquement des **commandes**, pas de scripts. Chaque étape indique le résultat attendu (✅)
  et quoi faire sinon (❌).

## Contenu du dépôt

```
install/                       Values Helm des outils (images JFrog, options)
  values-argo-rollouts.yaml      CRD de vérification utilisées par Kargo
  values-kargo.yaml              Kargo
  values-argo-workflows.yaml     Porte de mise en prod (approbation)
  httproutes.yaml                Exposition des UI Kargo et Argo Workflows via la Gateway
charts/excalidraw/             Chart Helm de l'application (Deployment, Service, HTTPRoute)
  values.yaml                    Valeurs par défaut, communes aux environnements
env/<dev|staging|prod>/        Values propres à chaque environnement (image, réplicas, HTTPRoute…)
  values.yaml
argocd/applications.yaml       3 Applications Argo CD (une par namespace)
kargo/                         Projet, Warehouse, tâches de promotion, vérification, stages, RBAC
argo-workflows/prod-gate.yaml  Workflow d'approbation avant la prod
secrets/                       Identifiants (jamais poussés dans Git)
```

## Comment ça marche

```
JFrog (image excalidraw) ─┐
                          ├─► Warehouse ─► Freight ─► dev ─────► staging ──────► prod
Azure Repos main          ┘   (image +      (lot       auto +     auto +          manuel, 9h-17h,
 (charts/, env/)               config)       versionné) smoke      smoke, rollback  soak 10 min,
                                                                                    approbation
Chaque promotion : values de l'env + tag/digest de l'image ─► helm template ─► commit sur la
branche stage/<env> ─► Argo CD synchronise le namespace excalidraw-<env>
```

Une **Freight** est créée quand l'**image** change (nouveau digest de `latest`, ou autre tag
autorisé) **ou** quand la **configuration** change (commit dans `charts/` ou `env/` sur `main`).
Une modification de values se promeut donc exactement comme une nouvelle version.

| Namespace | Contenu |
|---|---|
| `argo-rollouts` | Argo Rollouts (CRD de vérification) |
| `kargo` | Kargo (contrôleurs, API, UI) |
| `argo` | Argo Workflows |
| `excalidraw-gates` | Workflows d'approbation de mise en prod |
| `excalidraw-poc` | Le projet Kargo (Warehouse, Freight, stages) |
| `excalidraw-dev`, `excalidraw-staging`, `excalidraw-prod` | Les trois environnements |

---

## Étape 0 — Vérifier le point de départ

```bash
kubectl config current-context
kubectl auth can-i create namespaces
kubectl auth can-i create customresourcedefinitions
kubectl get crd certificates.cert-manager.io
kubectl get pods -n argocd                         # adapter si Argo CD est ailleurs
kubectl get crd httproutes.gateway.networking.k8s.io
kubectl get gateway -A                             # Gateway à laquelle attacher les HTTPRoute
kubectl get crd analysistemplates.argoproj.io workflowtemplates.argoproj.io stages.kargo.akuity.io
helm version
```

✅ Bon contexte ; `yes` deux fois ; cert-manager et Argo CD présents ; la CRD HTTPRoute existe et
au moins une Gateway est listée (note son **nom** et son **namespace**) ; la dernière commande
répond `NotFound` pour les trois CRD.
❌ `no` → il faut un compte admin du cluster.
❌ Une des trois dernières CRD existe → Argo Rollouts, Argo Workflows ou Kargo est déjà là :
sauter son installation.

## Étape 1 — Rassembler les informations

**Azure DevOps**
1. *Repos* > *New repository* : dépôt vide, sans README.
2. URL HTTPS **sans `<org>@`** : `https://dev.azure.com/<org>/<projet>/_git/<depot>`.
3. *User settings* > *Personal access tokens* : PAT avec **Code : Read & write**.

**JFrog** (demander à l'équipe qui gère Artifactory si besoin)
- Le chemin Docker du dépôt *remote* qui proxifie **Docker Hub**, par ex.
  `monentreprise.jfrog.io/docker-remote` → l'image devient
  `monentreprise.jfrog.io/docker-remote/excalidraw/excalidraw`.
- Les chemins qui proxifient **ghcr.io** (image Kargo) et **quay.io** (images Argo).
- Un utilisateur + **jeton d'accès en lecture** sur ces dépôts.

**Gateway** : nom et namespace (étape 0), le domaine des applications, et la confirmation que
la Gateway **termine le HTTPS** (certificat couvrant `*.domaine` sur son listener) et accepte les
routes des namespaces `kargo`, `argo` et `excalidraw-*` (`allowedRoutes` du listener).

Définir les variables (garder ce terminal jusqu'à la fin) :

```bash
export GITOPS_REPO="https://dev.azure.com/<org>/<projet>/_git/kargo-poc-excalidraw"
export GIT_TOKEN="<PAT Azure DevOps>"
export ARGOCD_NS="argocd"

export JFROG_REGISTRY="monentreprise.jfrog.io"                       # hôte du registre
export EXCALIDRAW_IMAGE="$JFROG_REGISTRY/docker-remote/excalidraw/excalidraw"
export TOOLS_IMAGE="$JFROG_REGISTRY/docker-remote/curlimages/curl:8.10.1"   # tests HTTP
export JFROG_GHCR="$JFROG_REGISTRY/ghcr-remote"                      # proxy de ghcr.io
export JFROG_QUAY="$JFROG_REGISTRY/quay-remote"                      # proxy de quay.io
export JFROG_USER="<utilisateur JFrog>"
read -rs JFROG_TOKEN; export JFROG_TOKEN                             # jeton, saisi sans écho

export GATEWAY_NAME="<nom de la Gateway>"
export GATEWAY_NAMESPACE="<namespace de la Gateway>"
export APP_DOMAIN="apps.monentreprise.com"
export KARGO_HOST="kargo.$APP_DOMAIN"                 # URL publique de l'UI Kargo
export ARGOWF_HOST="argo-workflows.$APP_DOMAIN"       # URL publique de l'UI d'approbation
```

## Étape 2 — Personnaliser les fichiers

```bash
cd kargo-poc-excalidraw

grep -rlE '__[A-Z_]+__' install charts env argocd kargo argo-workflows secrets | xargs sed -i \
  -e "s#__GITOPS_REPO__#${GITOPS_REPO}#g" \
  -e "s#__GIT_USERNAME__#kargo#g" \
  -e "s#__GIT_TOKEN__#${GIT_TOKEN}#g" \
  -e "s#__ARGOCD_NS__#${ARGOCD_NS}#g" \
  -e "s#__DEST_SERVER__#https://kubernetes.default.svc#g" \
  -e "s#__EXCALIDRAW_IMAGE__#${EXCALIDRAW_IMAGE}#g" \
  -e "s#__TOOLS_IMAGE__#${TOOLS_IMAGE}#g" \
  -e "s#__JFROG_GHCR__#${JFROG_GHCR}#g" \
  -e "s#__JFROG_QUAY__#${JFROG_QUAY}#g" \
  -e "s#__GATEWAY_NAME__#${GATEWAY_NAME}#g" \
  -e "s#__GATEWAY_NAMESPACE__#${GATEWAY_NAMESPACE}#g" \
  -e "s#__APP_DOMAIN__#${APP_DOMAIN}#g" \
  -e "s#__KARGO_HOST__#${KARGO_HOST}#g" \
  -e "s#__ARGOWF_HOST__#${ARGOWF_HOST}#g" \
  -e "s#__GROUP_DEVS__#excalidraw-devs#g" \
  -e "s#__GROUP_RELEASE__#excalidraw-release-managers#g" \
  -e "s#__RANCHER_PROJECT_ID__#c-xxxxx:p-xxxxx#g"

grep -rnE '__[A-Z_]+__' install charts env argocd kargo argo-workflows secrets
```

✅ La dernière commande n'affiche **rien**.

Ensuite, relis et ajuste à ta convenance (ce sont tes fichiers de personnalisation) :
`install/*.yaml` (images des outils), `charts/excalidraw/values.yaml` et `env/*/values.yaml`
(image, réplicas, ressources, HTTPRoute…).

## Étape 3 — Pousser le dépôt et créer les branches d'environnement

```bash
git init -b main
git remote add origin "$GITOPS_REPO"
git add -A
git status --short | grep secrets/          # doit être VIDE : les secrets restent sur ton poste
git commit -m "POC Kargo Excalidraw"
git push -u origin main                      # utilisateur : n'importe quoi ; mot de passe : le PAT

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

✅ `main`, `stage/dev`, `stage/staging`, `stage/prod` en local et sur `origin` ; visibles dans
Azure DevOps > *Repos* > *Branches*.
❌ `Authentication failed` → PAT expiré ou sans *Code : Read & write*.

## Étape 4 — Accès à JFrog dans chaque namespace

Toutes les images (outils, Excalidraw, tests) sont tirées depuis JFrog avec un secret `jfrog-pull` :

```bash
for ns in argo-rollouts kargo argo excalidraw-gates excalidraw-dev excalidraw-staging excalidraw-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" create secret docker-registry jfrog-pull \
    --docker-server="$JFROG_REGISTRY" \
    --docker-username="$JFROG_USER" --docker-password="$JFROG_TOKEN"
done
kubectl get secret jfrog-pull -A
```

✅ Sept secrets `jfrog-pull` listés.
Le namespace `excalidraw-poc` sera créé par Kargo : son secret est ajouté à l'étape 9.

## Étape 5 — Installer Argo Rollouts (CRD de vérification)

À sauter si `analysistemplates.argoproj.io` existait à l'étape 0.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argo-rollouts argo/argo-rollouts -n argo-rollouts \
  -f install/values-argo-rollouts.yaml --wait
kubectl get pods -n argo-rollouts
kubectl get crd analysistemplates.argoproj.io analysisruns.argoproj.io
```

✅ Pod `argo-rollouts-*` `Running` ; les deux CRD existent.
❌ `ImagePullBackOff` → `kubectl describe pod -n argo-rollouts <pod>` : chemin `JFROG_QUAY` ou
droits du jeton JFrog. Si l'organisation n'autorise pas `argoproj.github.io`, remplacer l'URL du
`helm repo add` par le dépôt Helm *remote* JFrog équivalent.

## Étape 6 — Installer Kargo

```bash
KARGO_ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
KARGO_PASSWORD_HASH=$(htpasswd -bnBC 10 "" "$KARGO_ADMIN_PASSWORD" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
echo "Mot de passe admin Kargo : $KARGO_ADMIN_PASSWORD"          # NOTE-LE

helm install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.12.3 \
  -n kargo \
  -f install/values-kargo.yaml \
  --set api.adminAccount.passwordHash="$KARGO_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --wait
kubectl get pods -n kargo
```

✅ Tous les pods `kargo-*` sont `Running`.
❌ `htpasswd: command not found` → paquet `apache2-utils` (Debian/Ubuntu) ou `httpd-tools` (RHEL).
❌ Chart introuvable (accès à `ghcr.io` bloqué) → utiliser le dépôt OCI *remote* JFrog :
`oci://$JFROG_GHCR/akuity/kargo-charts/kargo` (après `helm registry login $JFROG_REGISTRY`).
❌ Pods bloqués en `ContainerCreating` → `kubectl get certificate -n kargo` (cert-manager) et
`kubectl describe pod -n kargo <pod>`.

L'UI Kargo sera exposée à l'étape 7b. En attendant, accès direct possible :

```bash
kubectl port-forward -n kargo svc/kargo-api 8080:80      # http://localhost:8080
```

✅ Page de connexion Kargo : **admin** + mot de passe noté.

## Étape 7 — Installer Argo Workflows (porte d'approbation)

```bash
helm install argo-workflows argo/argo-workflows -n argo \
  -f install/values-argo-workflows.yaml --wait
kubectl apply -f argo-workflows/prod-gate.yaml
kubectl get pods -n argo
kubectl get workflowtemplate -n excalidraw-gates
```

✅ `argo-workflows-server` et `argo-workflows-workflow-controller` `Running` ; template `prod-gate` présent.

Accès direct possible en attendant l'étape 7b :
`kubectl port-forward -n argo svc/argo-workflows-server 2746:2746` → http://localhost:2746.

## Étape 7b — Exposer Kargo et Argo Workflows (HTTPRoute)

```bash
kubectl apply -f install/httproutes.yaml
kubectl get httproute -n kargo kargo -o jsonpath='{.status.parents[0].conditions}'; echo
kubectl get httproute -n argo argo-workflows -o jsonpath='{.status.parents[0].conditions}'; echo
```

✅ Les conditions contiennent `"type":"Accepted","status":"True"` et `"type":"ResolvedRefs","status":"True"`.
Ouvrir `https://$KARGO_HOST` (connexion **admin**) et `https://$ARGOWF_HOST` (sans connexion).
❌ `Accepted: False` / `NotAllowedByListeners` → le listener de la Gateway n'accepte pas les routes
des namespaces `kargo` / `argo` : adapter son `allowedRoutes` (équipe plateforme).
❌ Page Kargo blanche ou erreurs de redirection → `api.host` de `install/values-kargo.yaml` doit être
exactement `$KARGO_HOST`, puis `helm upgrade kargo oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.3 -n kargo -f install/values-kargo.yaml --reuse-values`.

> ⚠️ **Avant durcissement**, Argo Workflows n'a **aucune authentification** : toute personne qui
> atteint `https://$ARGOWF_HOST` peut approuver ou rejeter une mise en prod. Pendant la POC,
> l'exposer uniquement sur une Gateway **interne** ou un réseau restreint. Voir « Durcissement ».

## Étape 8 — Brancher Argo CD sur les trois namespaces

```bash
kubectl apply -f secrets/argocd-repo.yaml
kubectl apply -f argocd/applications.yaml
kubectl get applications -n "$ARGOCD_NS" | grep excalidraw
```

✅ Trois Applications `excalidraw-dev|staging|prod`, **OutOfSync** ou **Unknown** : normal, les
branches `stage/*` sont encore vides. Kargo déclenchera leur premier sync.
❌ `authentication required` dans l'UI Argo CD → l'URL du secret et celle des Applications doivent
être **identiques** (attention à `org@`).

## Étape 9 — Créer le pipeline Kargo

```bash
kubectl apply -f kargo/00-project.yaml
until kubectl get namespace excalidraw-poc >/dev/null 2>&1; do sleep 2; done

kubectl apply -f secrets/kargo-git-credentials.yaml

kubectl -n excalidraw-poc create secret docker-registry jfrog-pull \
  --docker-server="$JFROG_REGISTRY" \
  --docker-username="$JFROG_USER" --docker-password="$JFROG_TOKEN"

kubectl -n excalidraw-poc create secret generic excalidraw-image-creds \
  --from-literal=repoURL="$EXCALIDRAW_IMAGE" \
  --from-literal=username="$JFROG_USER" --from-literal=password="$JFROG_TOKEN"
kubectl -n excalidraw-poc label secret excalidraw-image-creds kargo.akuity.io/cred-type=image

kubectl apply -f kargo/
kubectl get warehouse,stages -n excalidraw-poc
```

✅ Un Warehouse `excalidraw` et trois Stages `dev`, `staging`, `prod`. UI Kargo > projet
`excalidraw-poc` : pipeline `dev → staging → prod`.
Le secret `jfrog-pull` sert aux Jobs de test ; `excalidraw-image-creds` permet à Kargo de lister
les tags dans JFrog.

## Étape 10 — Première Freight : dev puis staging, sans rien faire

```bash
kubectl annotate warehouse excalidraw -n excalidraw-poc kargo.akuity.io/refresh="$(date +%s)" --overwrite
kubectl get freight -n excalidraw-poc -L kargo.akuity.io/alias
```

✅ Une Freight apparaît (alias du type `wise-otter`), contenant l'image `latest` + son digest et
le commit de `main`. Puis, en 5 à 10 minutes :

```bash
kubectl get promotions -n excalidraw-poc -o custom-columns=NOM:.metadata.name,STAGE:.spec.stage,PHASE:.status.phase
kubectl get applications -n "$ARGOCD_NS" | grep excalidraw     # dev puis staging : Synced / Healthy
kubectl get pods -n excalidraw-dev -o custom-columns=POD:.metadata.name,ETAT:.status.phase,IMAGE:.spec.containers[0].image
```

✅ Promotions `dev` puis `staging` en `Succeeded` ; dans Azure Repos, la branche `stage/dev`
contient `manifests.yaml` et `values-effectives.yaml` ; l'image des pods est
`…/excalidraw/excalidraw:latest@sha256:…`.

Voir l'application : `https://excalidraw-dev.$APP_DOMAIN` si `httpRoute.enabled: true` dans
`env/dev/values.yaml` (cf. « Faire évoluer l'application »), sinon :

```bash
kubectl port-forward -n excalidraw-dev svc/excalidraw 8081:80      # http://localhost:8081
```

❌ Pas de Freight → `kubectl get warehouse excalidraw -n excalidraw-poc -o jsonpath='{.status.conditions}'`.
Cas fréquent avec un dépôt *remote* JFrog : il ne connaît que les tags **déjà téléchargés une fois**.
Les mettre en cache, par ex. : `docker pull $EXCALIDRAW_IMAGE:latest` (et les tags `sha-…` de
`kargo/01-warehouse.yaml`), ou activer la liste des tags distants dans la configuration du dépôt.
❌ Promotion `Failed` → `kubectl get promotion <nom> -n excalidraw-poc -o jsonpath='{.status.message}'`.

## Étape 11 — Promouvoir en prod avec approbation

Conditions : Freight vérifiée en staging **depuis 10 min**, **lun–ven 9h–17h** (heure de Montréal).

Suivre le **Guide des interfaces** ci-dessous : parties A (promouvoir dans Kargo) et
B (approuver dans Argo Workflows), puis C (vérifier).

✅ Workflow `Succeeded`, promotion `Succeeded`, puis `kubectl get pods -n excalidraw-prod` → 2 pods.
❌ Promotion refusée dès sa création → hors fenêtre ou soak pas écoulé. Pour tester hors heures
ouvrables : retirer le bloc `promotionWindows` de `kargo/00-project.yaml`, puis
`kubectl apply -f kargo/00-project.yaml`.

---

## Guide des interfaces

### A. Kargo — suivre et promouvoir (`https://$KARGO_HOST`)

**Se repérer**
1. Se connecter (**admin**). La page d'accueil liste les projets : ouvrir **excalidraw-poc**.
2. En haut, la **frise des Freight** : chaque carte est une version (image + config). Sa couleur
   indique le ou les stages qui l'utilisent. Pour afficher les alias (`wise-otter`…) : icône
   **entonnoir** de la frise > cocher *Alias*.
3. Au centre, le **pipeline** : le Warehouse `excalidraw`, puis les nœuds `dev` → `staging` → `prod`.
   Chaque nœud montre la Freight en place et l'état du stage (sain, en cours, en erreur, en
   vérification).

**Voir le détail d'une version**
- Clic sur une Freight de la frise : son contenu (tag + digest de l'image, commit de `main`) et la
  rubrique **VERIFIED IN**, qui liste les stages où elle a passé la vérification.
  Une Freight n'est proposée à `staging` que si `dev` figure dans cette liste, et à `prod` que si
  `staging` y figure (et après 10 min).

**Voir le détail d'un stage**
- Icône **barres empilées** dans l'en-tête du nœud : historique des promotions (chaque step,
  en direct), onglet **Verifications** (résultat des smoke tests), boutons **Refresh**,
  **Reverify** (relancer la vérification) et *Abort Verification*.

**Promouvoir** (dev et staging le font seuls ; prod à la main)
1. Icône **camion** dans l'en-tête du nœud `prod` > **Promote**.
2. Dans la frise, **Select** sur la Freight voulue (seules les Freight éligibles sont proposées).
3. **Promote**. Un panneau suit les steps en direct. Pour `prod`, la promotion reste sur le step
   de la porte (`wait-gate`) : passer à la partie B.

**Hotfix : autoriser une Freight sans passer par les stages précédents**
- Frise > **⋮** sur la Freight > **Manually Approve** > **Approve** sur le stage voulu.
  Elle devient promouvable vers ce stage ; l'approbation est tracée sur la Freight.

**Revenir à une version précédente**
- Promouvoir simplement l'ancienne Freight (Promote > Select l'ancienne). Sur `staging`, Kargo le
  fait seul si la vérification échoue (rollback automatique).

**Forcer Kargo à regarder le registre et Git** : clic sur le nœud du Warehouse > **Refresh**.

### B. Argo Workflows — approuver une mise en prod (`https://$ARGOWF_HOST`)

1. Menu de gauche **Workflows**, filtre namespace **excalidraw-gates**.
2. Ouvrir le workflow **prod-gate-xxxxx** le plus récent (statut *Running*).
3. Le graphe montre : `smoke-staging` (vert = staging répond), puis `approval` en **pause**.
   Le paramètre `image` du workflow indique la version candidate.
4. Bouton **RESUME** (barre du haut, ou panneau qui s'ouvre au clic sur le nœud `approval`) : renseigner `approve` = **YES** (ou **NO**) et un `comment`,
   puis valider.
5. `decision` s'exécute : vert si YES, rouge si NO. Le workflow passe *Succeeded* ou *Failed*.

Dans Kargo, la promotion `prod` reprend dans les 30 s : déploiement si YES, échec (prod
inchangée) si NO. Sans réponse sous 8 h, le workflow expire et la promotion échoue.

### C. Vérifier qu'une promotion a bien eu lieu

| Où | Quoi regarder | Attendu |
|---|---|---|
| UI Kargo | Nœud du stage | La nouvelle Freight est en place, stage sain, vérification réussie |
| Azure Repos | Branche `stage/<env>` | Nouveau commit `<env> : Excalidraw <tag>` ; `values-effectives.yaml` montre le tag, le digest et les réglages de l'environnement |
| Argo CD | Application `excalidraw-<env>` | **Synced** sur ce commit, **Healthy** |
| Cluster | `kubectl get pods -n excalidraw-<env> -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image` | Pods `Running` avec `…:<tag>@sha256:<digest>` |
| Application | `https://excalidraw-<env>.$APP_DOMAIN` (si `httpRoute.enabled: true`) ou port-forward | Excalidraw s'affiche |

## Faire évoluer l'application sans build

| Pour montrer… | Faire | Effet |
|---|---|---|
| Un changement de **configuration** | Modifier `env/dev/values.yaml` (ex. `replicaCount: 2`, `podLabels`), commit + push sur `main` | Nouvelle Freight → dev et staging se mettent à jour seuls ; la prod attend ta décision |
| Une **autre version d'image** | Dans `kargo/01-warehouse.yaml`, ne garder que `- ^sha-cc201a6$` dans `allowTagsRegexes`, puis `kubectl apply -f kargo/01-warehouse.yaml` | Nouvelle Freight avec une image différente (build de 2021) ; remettre la liste d'origine pour revenir à `latest` |
| L'**exposition HTTPRoute** | `httpRoute.enabled: true` dans `env/<env>/values.yaml`, commit + push | Le HTTPRoute est créé dans le namespace à la promotion suivante (la Gateway doit accepter les routes de ces namespaces) |
| Une **mise à jour réelle** | Rien : quand Docker Hub met à jour `latest`, JFrog et Kargo voient un nouveau digest | Nouvelle Freight automatique |

## Scénarios de démo

| # | Scénario | Comment | Attendu |
|---|---|---|---|
| 1 | Flux nominal | Changement de config (tableau ci-dessus) | dev puis staging automatiques ; prod sur décision |
| 2 | Approbation | Étape 11 avec `YES` | Prod mise à jour, décision et commentaire tracés dans le workflow |
| 3 | Refus | Étape 11 avec `NO` | Workflow et promotion `Failed`, prod inchangée |
| 4 | Mauvaise configuration | `replicaCount: 0` dans `env/dev/values.yaml` **et** `env/staging/values.yaml`, un seul commit + push | dev se déploie, mais plus aucun pod ne répond : smoke test `Failed`, la Freight n'est pas vérifiée, staging n'est pas touché |
| 5 | Rollback auto | UI Kargo : Freight du scénario 4 > *Manually Approve* > `staging` (elle y est promue) | Vérification staging `Failed` → Kargo repromeut seul la dernière Freight stable de staging |
| 6 | Hotfix | UI Kargo : Freight > *Manually Approve* > `prod` | Prod accessible sans passer par staging, tracé sur la Freight |
| 7 | Gel des déploiements | Promouvoir en prod un samedi ou après 17h | Refusé |
| 8 | Contrôle sécurité JFrog | Une image bloquée par une politique Xray | Pods `ImagePullBackOff` (403), vérification `Failed` : la version ne descend pas |

Après les scénarios 4 et 5, annuler le changement (`git revert HEAD` + `git push`) : la Freight saine qui en résulte repart dans le pipeline.

## Dépannage — commandes utiles

| Je veux voir… | Commande |
|---|---|
| Détection des versions | `kubectl get warehouse excalidraw -n excalidraw-poc -o jsonpath='{.status.conditions}'` |
| Versions détectées | `kubectl get freight -n excalidraw-poc -L kargo.akuity.io/alias` |
| État des stages | `kubectl get stages -n excalidraw-poc` |
| Raison d'un échec de promotion | `kubectl get promotions -n excalidraw-poc -o custom-columns=NOM:.metadata.name,STAGE:.spec.stage,PHASE:.status.phase,MESSAGE:.status.message` |
| Vérifications | `kubectl get analysisruns,jobs -n excalidraw-poc` puis `kubectl logs job/<nom> -n excalidraw-poc` |
| Argo CD | `kubectl get applications -n "$ARGOCD_NS" -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,SANTE:.status.health.status` |
| Pods d'un environnement | `kubectl get pods -n excalidraw-<env> -o wide` |
| Ce que Kargo a rendu | Azure Repos > branche `stage/<env>` > `manifests.yaml` et `values-effectives.yaml` |
| Porte de prod | `kubectl get workflows -n excalidraw-gates` puis `kubectl describe workflow <nom> -n excalidraw-gates` |
| Logs Kargo | `kubectl logs -n kargo deploy/kargo-controller --tail=100` |

| Symptôme | Cause probable | Correction |
|---|---|---|
| Pas de Freight | Tags non mis en cache par le remote JFrog ; secret `excalidraw-image-creds` | Mettre les tags en cache ; vérifier repoURL = `EXCALIDRAW_IMAGE` exactement |
| `git-push` / `git-clone` en échec | PAT expiré ou scope insuffisant ; `org@` dans l'URL | Nouveau PAT, puis `kubectl apply -f secrets/kargo-git-credentials.yaml` |
| `helm-template` en échec | Erreur dans un fichier values | Tester en local : `helm template x charts/excalidraw -f env/dev/values.yaml` |
| `argocd-update` refusé | Namespace Argo CD | `controller.argocd.namespace` dans `install/values-kargo.yaml`, puis `helm upgrade kargo … -f install/values-kargo.yaml` |
| Pods `ImagePullBackOff` | Secret `jfrog-pull` absent ou jeton ; politique Xray | `kubectl describe pod` : 401 = identifiants, 403 = blocage Xray |
| HTTPRoute non accepté | Gateway qui n'accepte pas ces namespaces | `kubectl describe httproute excalidraw -n excalidraw-<env>` ; `allowedRoutes` du listener (les namespaces portent le label `app.kubernetes.io/part-of: excalidraw-poc`) |
| Promotion prod bloquée en `Running` | Approbation en attente | UI Argo Workflows > `approval` > Resume |

## Retour arrière complet

```bash
kubectl delete -f install/httproutes.yaml
kubectl delete -f argocd/applications.yaml
kubectl delete -f secrets/argocd-repo.yaml
kubectl delete project.kargo.akuity.io excalidraw-poc
helm uninstall argo-workflows -n argo
helm uninstall kargo -n kargo
helm uninstall argo-rollouts -n argo-rollouts       # seulement si installé à l'étape 5
kubectl delete namespace excalidraw-dev excalidraw-staging excalidraw-prod excalidraw-gates argo kargo argo-rollouts
```

cert-manager, Argo CD et la Gateway ne sont pas touchés.

## Durcissement (après la POC)

À faire avant tout usage au-delà de la démonstration, par ordre d'importance :

1. **Argo Workflows** : `server.authModes: [sso]` dans `install/values-argo-workflows.yaml`, branché
   sur Entra ID, avec un RBAC qui limite le *Resume* aux release managers. Kargo appelle alors l'API
   avec un jeton de ServiceAccount (en-tête `Authorization` du step `http`).
2. **Kargo** : SSO OIDC (Entra ID) via `api.oidc` du chart, puis désactiver le compte admin
   (`api.adminAccount.enabled: false`). Les rôles de `kargo/05-rbac.yaml` (développeurs vs
   release managers) deviennent actifs.
3. **Identifiants** : remplacer le PAT personnel par un compte de service Azure DevOps ; jetons JFrog
   dédiés en lecture seule ; secrets gérés par l'outil de l'entreprise (Vault, External Secrets…).
4. **Exposition** : Gateway interne uniquement, ou restriction d'adresses IP sur les deux UI.

## Limites connues

- Approbation dans Argo Workflows : **deuxième interface** ; pour deux approbateurs, deux étapes
  `suspend` successives.
- Avant durcissement, Argo Workflows est exposé **sans authentification** et Kargo avec un simple
  compte admin (cf. Durcissement).
- Docker Hub ne publie pas de versions numérotées d'Excalidraw (`latest` + anciens `sha-…`) : les
  « versions » de la démo sont donc des digests et des changements de configuration.
- Les trois environnements partagent un cluster.
- Le PAT Azure DevOps est personnel et expire : pour la cible, un compte de service.
- Champs vérifiés sur la doc Kargo v1.12 (oct. 2026) ; Kargo 2.0 est annoncé.
