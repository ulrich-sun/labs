# Contrat entre Kargo et les WorkflowTemplates

Kargo soumet chaque WorkflowTemplate avec **les mêmes 6 paramètres**, quel que
soit le template (cf. `kargo/02-promotion-tasks.yaml`). Un template doit donc
**tous** les déclarer, même s'il n'en utilise que certains :

| Paramètre   | Contenu                                                        |
|-------------|----------------------------------------------------------------|
| `image`     | image promue, `repo:tag@sha256:digest`                         |
| `stage`     | stage Kargo cible (`staging`, `prod`)                          |
| `freight`   | alias de la Freight promue (ex. `wise-otter`)                  |
| `actor`     | qui a lancé la promotion (`auto` pour une auto-promotion)      |
| `promotion` | nom de la ressource Promotion Kargo                            |
| `check-url` | URL à tester (environnement précédent), vide si sans objet     |

Résultat attendu par Kargo :
- workflow **Succeeded** → l'étape réussit, la promotion continue ;
- workflow **Failed / Error** → l'étape échoue, la promotion s'arrête (rien n'est déployé) ;
- workflow en cours (ou en pause) → Kargo attend.

Pour créer un nouveau *custom step* : copier `custom-precheck.yaml`, changer
`metadata.name` et la logique des conteneurs, puis l'ajouter à la pile d'un
Stage (`kargo/04-stages.yaml`) avec la tâche `custom-step`.
