# Désinstaller la POC Kargo — Excalidraw

Retire tout ce que la POC a installé dans le cluster, puis hors du cluster.
**cert-manager, Argo CD et la Gateway ne sont pas touchés.**

L'ordre compte : les objets Kargo et Argo Workflows sont supprimés **pendant que leurs
contrôleurs tournent encore**. Sinon, leurs finalizers bloquent les namespaces en `Terminating`.

Uniquement des commandes, à lancer dans l'ordre, dans le même terminal.

## Étape 0 — Point de départ

```bash
kubectl config current-context                  # le bon cluster
export ARGOCD_NS="argocd"                        # namespace de ton Argo CD

helm list -A | grep -E 'kargo|argo-workflows|argo-rollouts'
kubectl get ns | grep -E 'kargo|^argo |argo-rollouts|excalidraw'
```

✅ Bon contexte ; les releases et namespaces de la POC sont listés.
Note si **`argo-rollouts`** apparaît dans `helm list` : s'il n'y est pas, Argo Rollouts n'a pas été
installé par la POC et **ne doit pas être supprimé** (étapes 5, 6 et 7).

## Étape 1 — Le projet Kargo (Kargo encore en marche)

Supprime le namespace `excalidraw-poc` et tout ce qu'il contient : Warehouse, Freight, stages,
promotions, vérifications, secrets Git et JFrog du projet.

```bash
kubectl delete project.kargo.akuity.io excalidraw-poc
kubectl wait --for=delete namespace/excalidraw-poc --timeout=180s
```

✅ `namespace/excalidraw-poc condition met`.
❌ Délai dépassé → voir « Namespace bloqué en Terminating » en fin de fichier.

## Étape 2 — Les objets Argo CD de la POC

```bash
kubectl delete application excalidraw-dev excalidraw-staging excalidraw-prod -n "$ARGOCD_NS" --ignore-not-found
kubectl delete appproject excalidraw-poc -n "$ARGOCD_NS" --ignore-not-found
kubectl delete secret excalidraw-poc-repo -n "$ARGOCD_NS" --ignore-not-found
kubectl get applications -n "$ARGOCD_NS" | grep excalidraw
```

✅ La dernière commande n'affiche **rien**.
❌ Une Application reste en suppression → `kubectl patch application <nom> -n "$ARGOCD_NS" --type merge -p '{"metadata":{"finalizers":null}}'`.

## Étape 3 — Les workflows (Argo Workflows encore en marche)

```bash
kubectl delete workflows --all -n excalidraw-gates
kubectl delete workflowtemplates --all -n excalidraw-gates
kubectl get workflows,workflowtemplates -n excalidraw-gates
```

✅ `No resources found`.

## Étape 4 — L'exposition (HTTPRoute)

```bash
kubectl delete httproute kargo -n kargo --ignore-not-found
kubectl delete httproute argo-workflows -n argo --ignore-not-found
```

✅ Routes supprimées. La Gateway elle-même n'est pas modifiée.

Les HTTPRoute d'Excalidraw (`excalidraw-dev|staging|prod`) partent avec leurs namespaces à l'étape 6.

## Étape 5 — Les outils

```bash
helm uninstall argo-workflows -n argo
helm uninstall kargo -n kargo
helm uninstall argo-rollouts -n argo-rollouts     # SEULEMENT s'il était dans helm list (étape 0)
helm list -A | grep -E 'kargo|argo-workflows|argo-rollouts'
```

✅ La dernière commande n'affiche **rien** (ou seulement un Argo Rollouts qui n'est pas à la POC).

## Étape 6 — Les namespaces

```bash
kubectl delete namespace excalidraw-dev excalidraw-staging excalidraw-prod excalidraw-gates argo kargo --ignore-not-found
kubectl delete namespace argo-rollouts --ignore-not-found     # SEULEMENT si installé par la POC
kubectl get ns | grep -E 'kargo|^argo |argo-rollouts|excalidraw'
```

✅ La dernière commande n'affiche **rien** (après une à deux minutes).
❌ Un namespace reste en `Terminating` → voir en fin de fichier.

## Étape 7 — Les CRD

`helm uninstall` ne supprime pas les CRD.

> ⚠️ **Ne jamais supprimer tout le groupe `argoproj.io`** : Argo CD y a ses propres CRD
> (`applications`, `appprojects`, `applicationsets`). Supprimer **uniquement** les CRD listées
> ci-dessous.

Vérifier d'abord que personne d'autre ne s'en sert :

```bash
kubectl get workflows,workflowtemplates,cronworkflows -A 2>/dev/null
kubectl get rollouts,analysistemplates,analysisruns -A 2>/dev/null
```

✅ `No resources found` partout. ❌ Des objets existent dans d'autres namespaces → une autre équipe
utilise ces outils : **ne pas** supprimer les CRD correspondantes.

```bash
# Kargo
kubectl get crd -o name | grep 'kargo.akuity.io' | xargs -r kubectl delete

# Argo Workflows
kubectl delete crd \
  clusterworkflowtemplates.argoproj.io cronworkflows.argoproj.io \
  workflowartifactgctasks.argoproj.io workfloweventbindings.argoproj.io \
  workflows.argoproj.io workflowtaskresults.argoproj.io \
  workflowtasksets.argoproj.io workflowtemplates.argoproj.io --ignore-not-found

# Argo Rollouts : SEULEMENT si installé par la POC
kubectl delete crd \
  analysisruns.argoproj.io analysistemplates.argoproj.io \
  clusteranalysistemplates.argoproj.io experiments.argoproj.io \
  rollouts.argoproj.io --ignore-not-found
```

✅ CRD supprimées.

## Étape 8 — Vérifier qu'il ne reste rien dans le cluster

```bash
kubectl get ns | grep -E 'kargo|^argo |argo-rollouts|excalidraw'
kubectl get crd | grep -E 'kargo|workflow|rollout|analysis|experiment'
kubectl get clusterrole,clusterrolebinding | grep -E 'kargo|argo-workflows|argo-rollouts'
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep -i kargo
kubectl get applications,appprojects -n "$ARGOCD_NS" | grep excalidraw
kubectl get crd applications.argoproj.io appprojects.argoproj.io      # Argo CD intact
```

✅ Les cinq premières commandes n'affichent **rien** ; la dernière liste les deux CRD d'Argo CD.
❌ Un ClusterRole ou un webhook Kargo reste → `kubectl delete clusterrole <nom>` /
`kubectl delete validatingwebhookconfiguration <nom>` (vérifier d'abord qu'il porte bien le nom de
la POC).

## Étape 9 — Hors du cluster

**Azure DevOps**
- *Repos* > *Branches* : supprimer `stage/dev`, `stage/staging`, `stage/prod` et les éventuelles
  `kargo/promotion/*` ; fermer les Pull Requests ouvertes par Kargo. Ou supprimer le dépôt entier.
- *User settings* > *Personal access tokens* : **révoquer** le PAT de la POC.

**JFrog** : révoquer le jeton d'accès utilisé pour la POC.

**Ton poste** : supprimer le dossier `secrets/` (il contient le PAT en clair) et fermer le
terminal (variables `GIT_TOKEN`, `JFROG_TOKEN`).

```bash
rm -rf secrets/
```

---

## Namespace bloqué en `Terminating`

Cause : un objet garde un finalizer, en général parce que son contrôleur a été désinstallé avant
lui.

```bash
NS=<namespace bloqué>
kubectl get namespace "$NS" -o jsonpath='{.status.conditions}'; echo
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 kubectl get -n "$NS" --ignore-not-found --show-kind -o name
```

✅ La dernière commande liste les objets restants (par ex. `promotion.kargo.akuity.io/…`).
Retirer le finalizer de chacun :

```bash
kubectl patch <type>/<nom> -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}'
```

✅ Le namespace disparaît dans la minute.
