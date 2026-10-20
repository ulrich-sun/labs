# POC Kargo + Argo CD + Argo Workflows — Excalidraw sur AWS

Promotion d'Excalidraw entre trois **namespaces** d'un cluster k3s sur une VM EC2 :
`excalidraw-dev` → `excalidraw-staging` → `excalidraw-prod`.

- **Aucun build d'image, dans aucun contexte** : seules des images officielles publiques, sans
  modification (`excalidraw/excalidraw`, `nginxinc/nginx-unprivileged`, `curlimages/curl`,
  et les images des outils).
- **PSA `restricted` sur tout le cluster** : un conteneur qui tourne en root est refusé par l'API
  (seul `kube-system` est exempté).
- **Kargo open source** : les concepts **wait-for-approval** et **custom promotion steps**
  (réservés à Kargo sur Akuity Platform) sont reproduits avec **Argo Workflows**, appelé par
  l'étape native `http`.
- Interfaces exposées par la **Gateway API** (Traefik de k3s + `HTTPRoute`) sur
  `http://<app>.apps.<IP>.sslip.io` (ex. `http://kargo.apps.98.90.197.103.sslip.io`) :
  aucun DNS à gérer. Ports 22, 80 et 443 ouverts **uniquement depuis ton IP**.

## Contenu

```
infra/terraform/          VM EC2 + k3s (PSA restricted par défaut, Traefik en contrôleur Gateway API) + Helm
gateway/                  Gateway "apps" + HTTPRoutes de Kargo, Argo CD, Argo Workflows
install/                  Values Helm : cert-manager, Argo CD, Argo Rollouts, Kargo, Argo Workflows
charts/excalidraw/        Chart de l'application (conforme PSA restricted, sans build)
env/<dev|staging|prod>/   Values propres à chaque environnement
argocd/                   AppProject + 3 Applications (une par namespace)
argo-workflows/           Custom steps et porte d'approbation (WorkflowTemplates)
kargo/                    Projet, Warehouse, tâches de promotion, vérification, stages
secrets/                  Modèles d'identifiants (*.example) ; les vrais ne sont jamais poussés
tests/psa/                Preuve que la PSA refuse un conteneur root
```

## Concepts mis en avant

### 1. La pile d'étapes de promotion (promotion steps stack)

Dans Kargo, une promotion est une **suite ordonnée d'étapes**. Les étapes sont regroupées en
**PromotionTasks** réutilisables (`kargo/02-promotion-tasks.yaml`), que chaque Stage **empile**
(`kargo/04-stages.yaml`) :

```
dev      [deploy]                                                     auto
staging  [precheck] ─► [deploy]                                       auto
prod     [precheck] ─► [approval] ─► [deploy] ─► [release-record]     manuel
            custom      wait-for     natif        custom
            step        approval     Kargo        step
```

`deploy` (`render-and-sync`) n'utilise que des étapes natives : `git-clone` → `yaml-update`
(tag + digest de la Freight) → `helm-template` → `git-commit` → `git-push` sur `stage/<env>` →
`argocd-update` (sync et attente de l'état Healthy).

### 2. Custom steps

| | Kargo Akuity Platform | Cette POC (open source) |
|---|---|---|
| Définition | Ressource cluster `CustomPromotionStep` + image OCI | `WorkflowTemplate` Argo Workflows (`argo-workflows/custom-*.yaml`) |
| Appel | `uses: <nom-du-step>` | tâche `custom-step` : `http` POST (soumission) puis `http` GET en boucle (attente) |
| Contexte transmis | entrées du step | paramètres `image`, `stage`, `freight`, `actor`, `promotion`, `check-url` |
| Échec | step en échec | workflow `Failed` → promotion en échec, rien n'est déployé |

Deux custom steps fournis :
- `custom-precheck` (avant déploiement) : l'environnement précédent sert bien Excalidraw +
  politique d'image (registre autorisé, épinglage par digest) ;
- `custom-release-record` (après déploiement) : écrit une trace de la mise en production
  (ConfigMap). Remplaçable par un ticket ITSM, un message Teams/Slack, etc.

### 3. Wait-for-approval

| | Kargo Akuity Platform (≥ 1.12) | Cette POC (open source) |
|---|---|---|
| Étape | `uses: wait-for-approval` (`approvers`, `minApprovals`) | tâche `wait-for-approval` → WorkflowTemplate `approval-gate` |
| Où l'on approuve | UI Kargo | UI Argo Workflows : nœud `approval` > **Resume** |
| Trace | `responses` (utilisateur, action, date, message) | paramètres `approve`, `approver`, `comment` du workflow |
| Refus / délai | promotion en échec | `NO` ou 8 h sans réponse → promotion en échec |
| Plusieurs approbateurs | `minApprovals: 2` | dupliquer le couple `approval` / `decision` |

Autres contrôles **natifs** Kargo montrés : auto-promotion par stage (`ProjectConfig`), Freight
vérifiée obligatoire pour passer au stage suivant, `requiredSoakTime`, fenêtre de promotion,
approbation manuelle de Freight (hotfix), variante par Pull Request GitHub (`git-wait-for-pr`).

### 4. PSA restricted sans build

L'image officielle `excalidraw/excalidraw` lance nginx **en root sur le port 80** : refusée. Le
chart contourne cela sans rien reconstruire :
1. un **initContainer** utilise l'image Excalidraw officielle (celle que Kargo promeut), lancée
   en uid 101, pour copier les fichiers statiques dans un volume `emptyDir` ;
2. le conteneur **`nginxinc/nginx-unprivileged`** (image officielle non-root, port 8080) les sert.

Les deux conteneurs ont `runAsNonRoot`, `seccompProfile: RuntimeDefault`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` et un système de fichiers racine
en lecture seule. Les outils (Kargo, Argo Workflows…) reçoivent aussi des `securityContext`
explicites dans `install/`.

---

## Étape 0 — Prérequis (sur ton poste)

- Un compte AWS de test, avec des identifiants actifs dans le terminal (`AWS_PROFILE` ou
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) et le droit de créer EC2, SG et key pair. Le
  compte doit avoir un **VPC par défaut** dans la région.
- Terraform ≥ 1.6, Git, un client SSH et une paire de clés (`ssh-keygen -t ed25519` si besoin).
- Un compte GitHub.

Coût : t3.medium + 30 Go gp3, environ 1,2 USD/jour. **Détruire après la démo** (étape 14).

Toutes les commandes sont en **bash** (Git Bash sous Windows).

## Étape 1 — Dépôt GitOps sur GitHub

1. Créer un dépôt **vide** (sans README), par ex. `kargo-poc-excalidraw`, public ou privé.
2. Créer un jeton *fine-grained* : *Settings* > *Developer settings* > *Fine-grained tokens* ;
   accès **à ce seul dépôt** ; permissions **Contents : Read and write** et **Pull requests :
   Read and write**.

```bash
export GITOPS_REPO="https://github.com/<ton-compte>/kargo-poc-excalidraw.git"
read -rs GIT_TOKEN; export GIT_TOKEN          # jeton, saisi sans écho
```

## Étape 2 — Personnaliser et pousser le dépôt

Depuis une **copie** du dossier `kargo-poc-aws` (le dépôt GitOps a sa propre histoire) :

```bash
cp -r kargo-poc-aws ~/kargo-poc-excalidraw && cd ~/kargo-poc-excalidraw

grep -rl '__GITOPS_REPO__' argocd kargo secrets | xargs sed -i "s#__GITOPS_REPO__#${GITOPS_REPO}#g"
grep -rn '__GITOPS_REPO__' argocd kargo secrets      # doit être VIDE

git init -b main
git add -A
git status --short | grep -E 'secrets/.*\.yaml$|tfvars|tfstate'   # doit être VIDE
git commit -m "POC Kargo Excalidraw"
git remote add origin "$GITOPS_REPO"
git push -u origin main               # utilisateur : ton compte ; mot de passe : le jeton

# Branches de sortie, une par environnement (Kargo y écrira les manifests rendus)
for env in dev staging prod; do
  git checkout --orphan "stage/$env"
  git rm -rq --cached .
  echo "# Manifests rendus par Kargo pour $env" > STAGE.md
  git add STAGE.md && git commit -qm "init stage/$env"
  git push -u origin "stage/$env"
  rm STAGE.md && git checkout -qf main
done
git branch -a
```

✅ `main`, `stage/dev`, `stage/staging`, `stage/prod` visibles sur GitHub.
❌ `Authentication failed` → jeton expiré ou sans *Contents : Read and write*.

## Étape 3 — Créer la VM (Terraform)

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com          # ton IP -> allowed_ssh_cidr = "<IP>/32"
# éditer terraform.tfvars (région, chemin de la clé publique, IP)
terraform init
terraform apply
terraform output
```

✅ `public_ip`, `apps_domain`, `ssh` et `urls` affichés.
❌ `no matching EC2 VPC found` → la région n'a pas de VPC par défaut : `aws ec2 create-default-vpc`
ou changer de région.
⚠️ Avec tous les outils installés, la VM `t3.medium` est à ~70 % de RAM (Traefik : ~25 Mo) :
passer en `t3.large` si le compte l'autorise.
❌ `UnauthorizedOperation ... service control policy` (compte sandbox) → région ou type
d'instance interdit : rester en `us-east-1` et `t3.medium`.

Renseigner ensuite le domaine des applications (`apps.<IP>.sslip.io`) dans le dépôt GitOps :
Gateway, HTTPRoutes, `api.host` de Kargo, URL d'Argo CD et hostname d'Excalidraw par
environnement.

```bash
APPS_DOMAIN=$(terraform output -raw apps_domain)
cd ../..
grep -rl '__APPS_DOMAIN__' gateway install env | xargs sed -i "s#__APPS_DOMAIN__#${APPS_DOMAIN}#g"
grep -rn '__APPS_DOMAIN__' gateway install env      # doit être VIDE
git commit -am "Domaine des applications : ${APPS_DOMAIN}" && git push
```

> L'IP publique change si la VM est recréée : refaire ce remplacement (en partant de la
> nouvelle valeur au lieu de `__APPS_DOMAIN__`).

## Étape 4 — Cluster prêt et PSA active

```bash
ssh ubuntu@<public_ip>
# Les variables du poste n'existent pas sur la VM : les redéfinir
export GITOPS_REPO="https://github.com/<ton-compte>/kargo-poc-excalidraw.git"
read -rs GIT_TOKEN; export GIT_TOKEN
cloud-init status --wait                       # 2 à 4 min au premier démarrage
kubectl get nodes
helm version
```

✅ `status: done` ; un nœud `Ready` ; Helm répond.
❌ `status: error` → `sudo tail -50 /var/log/cloud-init-output.log`.

```bash
free -m                                        # Swap: 4095
```

✅ 4 Go de swap, créés par le user-data. **Indispensable en `t3.medium`** : une fois tous les
outils installés, `k3s-server` (~2 Go) et Argo CD saturent les 4 Go. Sans swap, l'API
Kubernetes ne répond plus, k3s plante (`Transaction commit failed`) et les promotions échouent
sur des délais dépassés.

**Preuve de la PSA** (dans un namespace **sans aucun label** : c'est le défaut du cluster qui
s'applique) :

```bash
git clone "$GITOPS_REPO" ~/poc && cd ~/poc     # dépôt privé : utilisateur + jeton
kubectl create namespace psa-test
kubectl apply -f tests/psa/root-pod.yaml
```

✅ `Error from server (Forbidden): ... violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false ..., runAsNonRoot != true ...`

```bash
kubectl apply -f tests/psa/compliant-pod.yaml
kubectl wait -n psa-test --for=condition=Ready pod/psa-test-ok --timeout=180s
kubectl delete namespace psa-test
```

✅ `pod/psa-test-ok condition met` : même image Excalidraw, **sans build**, acceptée en non-root.

> Pour la suite, **après chaque installation**, lancer :
> `kubectl get events -A --field-selector reason=FailedCreate | grep -i podsecurity`
> ✅ Rien. ❌ Une ligne → un pod de l'outil est refusé par la PSA (cf. Dépannage).

## Étape 5 — Installer les outils

Tout se fait **sur la VM**, dans `~/poc`.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# cert-manager (certificats des webhooks Kargo)
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  -f install/values-cert-manager.yaml --wait

# Argo CD
helm install argocd argo/argo-cd -n argocd --create-namespace \
  -f install/values-argocd.yaml --wait

# Argo Rollouts (CRD AnalysisTemplate, utilisées par les vérifications Kargo)
helm install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace \
  -f install/values-argo-rollouts.yaml --wait

kubectl get pods -A | grep -v kube-system
kubectl get events -A --field-selector reason=FailedCreate | grep -i podsecurity
```

✅ Tous les pods `Running` (ou `Completed` pour les jobs).

```bash
# Kargo
KARGO_ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -d "=+/" | head -c 24)
KARGO_PASSWORD_HASH=$(htpasswd -bnBC 10 "" "$KARGO_ADMIN_PASSWORD" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
echo "Mot de passe admin Kargo : $KARGO_ADMIN_PASSWORD"     # NOTE-LE

helm install kargo oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.4 \
  -n kargo --create-namespace \
  -f install/values-kargo.yaml \
  --set api.adminAccount.passwordHash="$KARGO_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --wait --timeout 10m
kubectl get pods -n kargo
```

✅ Pods `kargo-*` `Running`.
❌ Pods en `CrashLoopBackOff` avec une erreur d'écriture ou de permission → cf. Dépannage, « Kargo et uid ».

```bash
# Argo Workflows : le namespace des workflows doit exister AVANT l'installation
kubectl create namespace excalidraw-gates
helm install argo-workflows argo/argo-workflows -n argo --create-namespace \
  -f install/values-argo-workflows.yaml --wait
kubectl apply -f argo-workflows/
kubectl get pods -n argo
kubectl get workflowtemplates -n excalidraw-gates
kubectl get events -A --field-selector reason=FailedCreate | grep -i podsecurity
```

✅ `argo-workflows-server` et `argo-workflows-workflow-controller` `Running` ; trois templates
(`approval-gate`, `custom-precheck`, `custom-release-record`) ; aucune violation PSA.

## Étape 6 — Brancher Argo CD

```bash
# Dépôt PRIVÉ seulement :
cp secrets/argocd-repo.yaml.example secrets/argocd-repo.yaml
sed -i "s#__GIT_TOKEN__#${GIT_TOKEN}#" secrets/argocd-repo.yaml
kubectl apply -f secrets/argocd-repo.yaml

kubectl apply -f argocd/applications.yaml
kubectl get applications -n argocd
```

✅ Trois Applications `excalidraw-dev|staging|prod`. Rien à déployer tant que Kargo n'a pas écrit
dans `stage/*` : *Synced* sans ressource ou *OutOfSync* sont normaux à ce stade.

## Étape 7 — Créer le pipeline Kargo

```bash
kubectl apply -f kargo/00-project.yaml
until kubectl get namespace excalidraw-poc >/dev/null 2>&1; do sleep 2; done

cp secrets/kargo-git-credentials.yaml.example secrets/kargo-git-credentials.yaml
sed -i "s#__GIT_TOKEN__#${GIT_TOKEN}#" secrets/kargo-git-credentials.yaml
kubectl apply -f secrets/kargo-git-credentials.yaml

kubectl apply -f kargo/
kubectl get warehouse,stages,promotiontasks -n excalidraw-poc
```

✅ Warehouse `excalidraw`, Stages `dev`, `staging`, `prod`, quatre PromotionTasks.

**Optionnel mais recommandé** : Docker Hub limite fortement les accès anonymes. Avec un compte
Docker Hub gratuit et un *access token* en lecture seule :

```bash
kubectl -n excalidraw-poc create secret generic dockerhub-creds \
  --from-literal=repoURL=docker.io/excalidraw/excalidraw \
  --from-literal=username=<compte-dockerhub> --from-literal=password=<token>
kubectl -n excalidraw-poc label secret dockerhub-creds kargo.akuity.io/cred-type=image
```

## Étape 8 — Exposer les interfaces (Gateway API)

Le Traefik de k3s est le contrôleur Gateway API (GatewayClass `traefik`, créée par le
user-data). Sur la VM :

```bash
kubectl get gatewayclass traefik                 # ACCEPTED True
kubectl apply -f gateway/
kubectl wait -n gateway gateway/apps --for=condition=Programmed --timeout=120s
kubectl get httproute -A
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

✅ Gateway `apps` `PROGRAMMED True` ; trois HTTPRoutes (`kargo`, `argocd`, `argo-workflows`).
Les routes d'Excalidraw sont rendues par le chart (`charts/excalidraw/templates/httproute.yaml`)
et arrivent avec chaque promotion.

Sur ton poste (`terraform output urls`) :

| UI | URL | Connexion |
|---|---|---|
| Kargo | http://kargo.apps.&lt;IP&gt;.sslip.io | `admin` / mot de passe de l'étape 5 |
| Argo CD | http://argocd.apps.&lt;IP&gt;.sslip.io | `admin` / mot de passe affiché ci-dessus |
| Argo Workflows | http://workflows.apps.&lt;IP&gt;.sslip.io | aucune (POC : protégé seulement par le security group) |

❌ Délai d'attente dépassé → ton IP a changé : `allowed_ssh_cidr` dans `terraform.tfvars`, puis
`terraform apply` (seul le security group est modifié).
❌ `404 page not found` (réponse de Traefik) → hostname absent des HTTPRoutes :
`kubectl get httproute -A -o yaml | grep -A3 'hostnames\|conditions'`.

## Étape 9 — Première Freight : dev puis staging, sans rien faire

```bash
kubectl annotate warehouse excalidraw -n excalidraw-poc kargo.akuity.io/refresh="$(date +%s)" --overwrite
kubectl get freight -n excalidraw-poc -L kargo.akuity.io/alias
```

✅ Une Freight (alias du type `wise-otter`) : image `latest` + digest + commit de `main`.
Puis, en quelques minutes :

```bash
kubectl get promotions -n excalidraw-poc \
  -o custom-columns=NOM:.metadata.name,STAGE:.spec.stage,PHASE:.status.phase
kubectl get workflows -n excalidraw-gates
kubectl get pods -n excalidraw-dev -o custom-columns=POD:.metadata.name,ETAT:.status.phase,IMAGE:.spec.initContainers[0].image
```

✅ Promotion `dev` puis `staging` en `Succeeded`. La promotion `staging` a lancé le custom step
**`custom-precheck-staging-xxxxx`** (visible dans l'UI Argo Workflows : nœuds `smoke` et
`policy` en parallèle). La branche `stage/dev` contient `manifests.yaml` et
`values-effectives.yaml`. L'image de l'initContainer est `…excalidraw:latest@sha256:…`.

Voir l'application : http://excalidraw-dev.apps.&lt;IP&gt;.sslip.io et
http://excalidraw-staging.apps.&lt;IP&gt;.sslip.io (HTTPRoute `excalidraw` de chaque namespace).

❌ Pas de Freight → `kubectl get warehouse excalidraw -n excalidraw-poc -o jsonpath='{.status.conditions}'`
(souvent `429 Too Many Requests` de Docker Hub : ajouter `dockerhub-creds`, étape 7).
❌ Promotion `Failed` → `kubectl get promotion <nom> -n excalidraw-poc -o jsonpath='{.status.message}'`.
❌ Promotion `Errored` sur un délai dépassé (`context deadline exceeded`) → VM saturée (cf. swap,
étape 4). L'auto-promotion ne relance pas : Kargo > stage > **Promote** sur la même Freight, ou :

```bash
FREIGHT=$(kubectl get stage dev -n excalidraw-poc -o jsonpath='{.status.freightHistory[0].items.*.name}')
kubectl get stage staging -n excalidraw-poc -o json | jq --arg f "$FREIGHT" \
  '{apiVersion:"kargo.akuity.io/v1alpha1",kind:"Promotion",metadata:{generateName:"staging-",namespace:"excalidraw-poc"},spec:({stage:"staging",freight:$f}+.spec.promotionTemplate.spec)}' \
  | kubectl create -f -
```

## Étape 10 — Promotion en prod : toute la pile

Condition : Freight vérifiée en staging **depuis 5 min** (`requiredSoakTime`).

**Dans Kargo** (http://kargo.apps.&lt;IP&gt;.sslip.io > projet `excalidraw-poc`)
1. Icône **camion** du nœud `prod` > **Promote** > **Select** sur la Freight > **Promote**.
2. Le panneau de la promotion montre la pile en direct :
   `precheck` ✅ → `approval` ⏳ (**Running** : la promotion attend).

**Dans Argo Workflows** (http://workflows.apps.&lt;IP&gt;.sslip.io, namespace `excalidraw-gates`)
3. Ouvrir `approval-prod-xxxxx` (statut *Running*), nœud `approval` en pause.
4. **RESUME** : `approve` = **YES**, `approver` = ton nom, `comment` = un mot > valider.
   ⚠️ La valeur par défaut est **NO** : un Resume sans la changer **rejette** la promotion.

**De retour dans Kargo** (dans les 20 s)
5. `approval` ✅ → `deploy` ✅ (Argo CD synchronisé) → `release-record` ✅, puis la vérification
   (smoke test) de `prod`.

```bash
kubectl get pods -n excalidraw-prod                          # 2 pods Running
kubectl get cm -n excalidraw-gates -l poc/release-record=true
kubectl get cm -n excalidraw-gates -l poc/release-record=true -o yaml | grep -A8 '^  data:'
```

✅ Deux pods en prod ; une ConfigMap `release-prod-…` avec Freight, image, auteur et date.

## Étape 11 — Scénarios de démo

| # | Scénario | Comment | Attendu |
|---|---|---|---|
| 1 | Changement de config | `env/dev/values.yaml` : `replicaCount: 2` ; commit + push sur `main` (depuis ton poste) | Nouvelle Freight → dev puis staging seuls ; prod attend |
| 2 | Approbation | Étape 10 avec `YES` | Prod mise à jour, décision tracée (workflow + ConfigMap) |
| 3 | Refus | Étape 10 avec `NO` | `decision` rouge, promotion `Failed`, **prod inchangée**, `deploy` jamais exécuté |
| 4 | Custom step bloquant | `kubectl scale deploy excalidraw -n excalidraw-staging --replicas=0`, puis promouvoir en prod | `precheck` → `smoke` échoue : **aucune approbation demandée**, prod inchangée. Rétablir : resync de `excalidraw-staging` dans Argo CD |
| 5 | Mauvaise config | `replicaCount: 0` dans `env/dev/values.yaml`, commit + push | dev déployé mais smoke test `Failed` : Freight non vérifiée, **staging non touché**. Annuler : `git revert HEAD && git push` |
| 6 | Autre version d'image | Dans `kargo/01-warehouse.yaml` ne garder que `^sha-cc201a6$`, `kubectl apply -f kargo/01-warehouse.yaml` | Nouvelle Freight (image de 2021, même mécanisme non-root) qui parcourt le pipeline |
| 7 | Retour arrière | Kargo > `prod` > Promote > Select l'**ancienne** Freight | Re-déploiement de la version précédente, avec la même pile (pré-contrôles + approbation) |
| 8 | Hotfix | Kargo > Freight > **⋮** > *Manually Approve* > `prod` | Freight promouvable en prod sans passer par staging ; tracé sur la Freight |
| 9 | Gel des déploiements | Décommenter `promotionWindows` dans `kargo/00-project.yaml`, `kubectl apply -f kargo/00-project.yaml`, promouvoir hors 9h–17h lun–ven | Promotion refusée |
| 10 | Approbation par PR | Dans `kargo/04-stages.yaml` (prod), `render-and-sync` → `render-pr-and-sync`, `kubectl apply -f kargo/04-stages.yaml` | Kargo ouvre une PR vers `stage/prod` et attend son merge sur GitHub |
| 11 | PSA | `kubectl apply -f tests/psa/root-pod.yaml` (dans un namespace de test) | Refusé |

Pour les scénarios 1, 5 et 6 (modifs sur `main`), faire le changement sur ton poste puis
`git pull` dans `~/poc` sur la VM si tu appliques des fichiers `kargo/` depuis la VM.

## Étape 12 — Ajouter son propre custom step

1. Copier `argo-workflows/custom-precheck.yaml` → `argo-workflows/custom-<nom>.yaml`, changer
   `metadata.name` et la logique. **Garder les 6 paramètres** (cf.
   `argo-workflows/00-params-contract.md`) et les `securityContext` (PSA).
2. `kubectl apply -f argo-workflows/custom-<nom>.yaml`
3. L'empiler dans un Stage (`kargo/04-stages.yaml`) :
   ```yaml
   - task:
       name: custom-step
     as: <nom>
     vars:
       - name: workflowTemplate
         value: custom-<nom>
   ```
4. `kubectl apply -f kargo/04-stages.yaml`

## Dépannage

| Je veux voir… | Commande |
|---|---|
| Refus PSA | `kubectl get events -A --field-selector reason=FailedCreate \| grep -i podsecurity` |
| Détection des versions | `kubectl get warehouse excalidraw -n excalidraw-poc -o jsonpath='{.status.conditions}'` |
| Freight | `kubectl get freight -n excalidraw-poc -L kargo.akuity.io/alias` |
| Échec de promotion | `kubectl get promotions -n excalidraw-poc -o custom-columns=NOM:.metadata.name,STAGE:.spec.stage,PHASE:.status.phase,MESSAGE:.status.message` |
| Vérifications | `kubectl get analysisruns,jobs -n excalidraw-poc` puis `kubectl logs job/<nom> -n excalidraw-poc` |
| Custom steps / approbations | `kubectl get workflows -n excalidraw-gates` ; `kubectl logs -n excalidraw-gates -l workflows.argoproj.io/workflow=<nom>` |
| Logs Kargo | `kubectl logs -n kargo deploy/kargo-controller --tail=100` |
| Mémoire de la VM | `kubectl top nodes` ; `free -m` |

| Symptôme | Cause probable | Correction |
|---|---|---|
| ReplicaSet sans pod, event `violates PodSecurity` | Un chart sans `securityContext` complet | Compléter le `securityContext` dans `install/values-<outil>.yaml` puis `helm upgrade`. En dernier recours, **pour un namespace d'outillage uniquement** : `kubectl label ns <ns> pod-security.kubernetes.io/enforce=baseline --overwrite` (refuse toujours les conteneurs privilégiés), jamais sur `excalidraw-*` |
| Kargo et uid : `permission denied` dans les logs Kargo | Image Kargo prévue pour un autre uid | Remplacer `runAsUser/runAsGroup: 65532` par `1000` dans `install/values-kargo.yaml`, puis `helm upgrade kargo … -f install/values-kargo.yaml --reuse-values` |
| Pas de Freight, `429` | Limite Docker Hub anonyme | Secret `dockerhub-creds` (étape 7) |
| `git-push` en échec | Jeton expiré ou sans *Contents : write* | Nouveau jeton, `kubectl apply -f secrets/kargo-git-credentials.yaml` |
| `precheck` / `approval` en échec immédiat (`HTTP 4xx`) | Template absent ou paramètre non déclaré | `kubectl get workflowtemplates -n excalidraw-gates` ; les 6 paramètres doivent être déclarés |
| Pod de workflow refusé (PSA) | Conteneur de template sans `securityContext` | Copier le bloc `securityContext` d'un template existant |
| Pods `OOMKilled` / VM lente | 4 Go justes | `instance_type = "t3.large"` dans `terraform.tfvars` puis `terraform apply` (la VM est **recréée** : refaire à partir de l'étape 4) |

Tester la soumission d'un workflow comme le fait Kargo (même chemin réseau) :

```bash
kubectl -n excalidraw-poc run gate-test --rm -i --restart=Never --image=docker.io/curlimages/curl:8.10.1 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"gate-test","image":"docker.io/curlimages/curl:8.10.1","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["curl","-s","-X","POST","http://argo-workflows-server.argo.svc:2746/api/v1/workflows/excalidraw-gates/submit","-H","Content-Type: application/json","-d","{\"namespace\":\"excalidraw-gates\",\"resourceKind\":\"WorkflowTemplate\",\"resourceName\":\"custom-precheck\",\"submitOptions\":{\"generateName\":\"test-\",\"parameters\":[\"image=docker.io/excalidraw/excalidraw:latest@sha256:0\",\"stage=test\",\"freight=test\",\"actor=moi\",\"promotion=test\",\"check-url=\"]}}"]}]}}'
kubectl get workflows -n excalidraw-gates
```

✅ JSON avec `"name":"test-xxxxx"` ; le workflow réussit.

## Étape 13 — Limites connues

- Interfaces en **HTTP** (pas de TLS) et Argo Workflows exposé **sans authentification** :
  protégés seulement par le security group (80/443 limités à ton IP). Ne pas ouvrir
  `allowed_http_cidr` à `0.0.0.0/0` dans cet état.
- Argo Workflows sans authentification :
  `approver` est déclaratif. Cible : `server.authModes: [sso]` + RBAC qui limite le *Resume*, et
  Kargo qui appelle l'API avec un jeton (en-tête `Authorization` des étapes `http`).
- Approbation dans une **deuxième interface** (Argo Workflows), contrairement au
  `wait-for-approval` natif d'Akuity qui est dans l'UI Kargo.
- `autoRollback` (ProjectConfig) **n'a pas d'effet** en open source : son contrôleur n'existe que
  dans Kargo Enterprise. Le retour arrière se fait en promouvant l'ancienne Freight (scénario 7).
- Kargo : compte admin unique ; le RBAC par rôle (développeurs vs release managers) demande OIDC.
- Docker Hub ne publie pas de versions numérotées d'Excalidraw (`latest` + anciens `sha-…`) : les
  « versions » sont des digests et des changements de configuration.
- Un seul nœud, trois environnements dans le même cluster.

## Étape 14 — Tout détruire

Sur ton poste :

```bash
cd infra/terraform
terraform destroy
```

✅ `Destroy complete! Resources: 4 destroyed.` — supprimer aussi le jeton GitHub et, si voulu, le dépôt GitOps.
