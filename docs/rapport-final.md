# Rapport final — Projet DevSecOps

**Application** : API REST Spring Boot (`devops-demo`, Spring Boot 4.1.2, Java 17)
**Branche de référence** : `devsecops-final`
**Environnement** : VM Vagrant Ubuntu 22.04, 4 Go de RAM, Jenkins 2.580.2 (`http://192.168.33.10:8080`)

> **Comment lire ce rapport.** Chaque affirmation technique renvoie à un fichier du dépôt
> ou à une capture numérotée. Les captures sont listées dans
> [`docs/captures/README.md`](captures/README.md) avec la commande exacte qui les produit :
> les résultats d'exécution (builds, tests, mesures sur la VM) sont donc prouvés par ces
> captures, et les seuils, versions et expressions cités ici sont ceux du dépôt, vérifiables
> en une commande.
>
> **Résultats de scan : à remplir.** Tout résultat produit par un outil de scan (Trivy,
> Dependency-Check, ZAP, gitleaks, SonarQube) est marqué
> `[À REMPLIR: résultat réel du scan]` : il se recopie depuis les captures du build Jenkins
> de la VM. Aucun chiffre de scan n'est affirmé ici avant d'avoir été produit par ce build.
> Les résultats de scripts (nombre de contrôles) et les faits du dépôt (seuils, versions,
> nombre de stages) ne sont pas concernés : ils se vérifient en une commande.

---

## 1. Contexte et périmètre

Le projet consiste à sécuriser une application Spring Boot existante à travers tout son
cycle de vie, en quatre phases : **développement**, **acceptation**, **production** et
**opérations**. La démarche retenue est celle d'un pipeline Jenkins unique qui *prouve*
chaque exigence par un stage bloquant et qui archive la preuve correspondante.

Trois principes ont guidé toutes les décisions :

1. **Aucune sécurité déclarative sans contrôle.** Chaque mesure annoncée est vérifiée par
   un test ou un script exécuté dans le pipeline ; une mesure non vérifiée n'est pas
   revendiquée.
2. **Aucun secret dans le dépôt.** Les secrets vivent dans les identifiants Jenkins ou
   dans un fichier `0600` ignoré par git.
3. **Aucune version inventée.** Chaque version d'outil est soit épinglée avec une
   empreinte, soit lue sur la VM (`docs/tools-table.md`).

### Organisation du dépôt

| Branche | Contenu |
|---|---|
| `main` | dépôt d'origine, jamais modifiée |
| `devsecops-phase1` | développement : modèle de menace, durcissement, hook pre-commit |
| `devsecops-phase2` | acceptation : image, scan, DAST, tests d'acceptation |
| `devsecops-phase3` | production : durcissement de la VM, secrets, smoke tests |
| `devsecops-phase4` | opérations : métriques, tableaux de bord, alertes |
| `devsecops-final` | Jenkinsfile consolidé + documentation de référence |

---

## 2. Phase 1 — Développement

### 2.1 Objectifs

Intégrer la sécurité dès l'écriture du code : connaître les menaces, valider les entrées,
ne pas fuiter d'information dans les erreurs, ne jamais committer de secret, et produire
une image Docker acceptable avant même de parler de déploiement.

### 2.2 Modèle de menace (STRIDE)

Le modèle complet se trouve dans [`docs/threat-model.md`](threat-model.md). Synthèse des
menaces retenues et de leur traitement :

| Menace (STRIDE) | Scénario concret | Traitement implémenté |
|---|---|---|
| **S**poofing | appel anonyme se faisant passer pour un client légitime | en-têtes de durcissement + secret d'exécution injecté au déploiement |
| **T**ampering | corps JSON malformé provoquant un comportement non prévu | validation Bean Validation + gestionnaire d'erreurs dédié |
| **R**epudiation | aucune trace d'une requête rejetée | journalisation des rejets, sans secret ni détail interne |
| **I**nformation disclosure | trace Java renvoyée au client, `/actuator/env` accessible | gestionnaire d'erreurs générique + surface Actuator réduite |
| **D**enial of service | requêtes coûteuses, corps non borné | validation stricte, erreurs 4xx immédiates |
| **E**levation of privilege | conteneur exécuté en root | `USER` non-root dans l'image, contrôlé en Phase 3 |

### 2.3 Mesures mises en œuvre

* **Validation et erreurs** : `@Valid` sur les entrées ; un `@RestControllerAdvice` renvoie
  un message neutre et journalise le détail côté serveur. La route inconnue renvoie **404**
  et non 500 (correctif de la Phase 2, voir §6).
* **En-têtes de sécurité** : `SecurityHeadersFilter` ajoute `X-Content-Type-Options:
  nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, et supprime toute
  bannière applicative.
* **Hook pre-commit** (`.githooks/pre-commit`) : `gitleaks protect` bloque le commit si un
  secret est détecté. Il est doublé côté serveur par le stage *Secrets scan*, car un hook
  se contourne avec `--no-verify`.
* **Dockerfile** : image de base épinglée, utilisateur non-root, aucune dépendance de
  build dans l'image finale, `hadolint` sans avertissement.
* **Dépendances maintenues** : Spring Boot 4.1.2 (spring-framework 7.0.10, Tomcat 11.0.27).
  Ce n'était pas le choix initial : un scan Trivy lancé **sur le poste de développement**
  (hors Jenkins) a détecté 9 CVE critiques dans la version 3.3.5, et la porte interdisant
  toute CVE CRITIQUE impose au minimum cette version. Le résultat qui fait foi est celui du
  build : `[À REMPLIR: résultat réel du scan]` (§6, difficulté 11).
* **Pipeline** : *Build* → *Unit and security tests* (10 tests) → *Secrets scan* →
  *Dependency scan (Dependency-Check)* → *Dependency scan (Trivy fs)* → *Dockerfile lint*.

### 2.4 Preuves

| Capture | Contenu |
|---|---|
| 1 | Pipeline Phase 1 vert, stages de sécurité visibles |
| 2 | Hook pre-commit qui refuse un faux secret |
| 3 | 10 tests JUnit passés |
| 4 | Rapport gitleaks — résultat : `[À REMPLIR: résultat réel du scan]` |
| 5 | Rapport HTML Dependency-Check — résultat : `[À REMPLIR: résultat réel du scan]` |
| 6 | hadolint — résultat : `[À REMPLIR: résultat réel du scan]` |
| 26 | Scan Trivy des dépendances (`reports/trivy-fs-resolved-report.txt`) — résultat : `[À REMPLIR: résultat réel du scan]` |

### 2.5 Limites de la phase

* Le hook pre-commit ne protège que les postes qui l'ont installé ; seule la version
  serveur est une garantie.
* Dependency-Check ne détecte que les CVE **publiées** ; il ne remplace pas une revue de
  code.
* **Deux scans de dépendances, complémentaires.** Dependency-Check interroge le flux NVD et
  exige une clé API valide ; le scan Trivy des dépendances résolues par Maven compare le
  même jeu à sa propre base, sans clé ni quota, et sans Docker. L'un reste utile quand
  l'autre est indisponible — les deux bases ne publient d'ailleurs pas le même jour.

---

## 3. Phase 2 — Acceptation

### 3.1 Objectifs

Prouver, avant tout déploiement en production, que l'**image** livrée et le **service
exécuté** respectent le contrat de sécurité : pas de CVE critique dans l'image, pas de
vulnérabilité web de base, codes de statut et en-têtes conformes, VM dans l'état attendu,
Dockerfile et Jenkinsfile conformes à la politique écrite.

### 3.2 Stages ajoutés

| Stage | Outil | Ce qu'il prouve | Échec si |
|---|---|---|---|
| Container image (build) | Docker | l'image se construit de façon reproductible | build impossible |
| Container scan (Trivy) | Trivy | aucune CVE **CRITIQUE** dans l'image | au moins une CRITIQUE |
| Deploy application container | Docker | l'image démarre et répond (port 18080) | pas prêt en 40 s |
| DAST (OWASP ZAP baseline) | ZAP 2.17.0 | pas de constat web bloquant | une règle ZAP `FAIL` |
| Security acceptance tests | script bash | 11 propriétés de sécurité du service | un des 11 contrôles |
| Infrastructure test (VM) | `infra-check.sh` | état de la VM (swap, Docker, pare-feu, outils) | anomalie dure |
| Compliance check (policy) | `compliance-check.sh` | politique Dockerfile/Jenkinsfile | un des 9 contrôles |

### 3.3 Tests d'acceptation (11 contrôles)

`scripts/security-acceptance-test.sh` vérifie, sur le service réellement déployé :
réponse nominale et corps attendu ; les trois en-têtes de durcissement ; refus d'un corps
JSON invalide (4xx, sans trace) ; refus d'un corps trop volumineux ; route inconnue en
404 ; `TRACE` refusé ; absence de bannière ; erreur interne renvoyée sans détail
(`/boom` journalise mais ne fuit pas).

### 3.4 Preuves

| Capture | Contenu |
|---|---|
| 7 | Tests d'acceptation : 11/11 |
| 8 | Rapport ZAP baseline (HTML) |
| 9 | Rapport Trivy de l'image — résultat : `[À REMPLIR: résultat réel du scan]` |
| 10 | Compliance : 9/9 |
| 11 | `infra-check.sh` sur la VM |
| 12 | Pipeline Phase 2 : 7 stages verts |

### 3.5 Limites de la phase

* ZAP est lancé en **baseline** : rapide et compatible avec 4 Go, mais il ne remplace pas un
  scan complet authentifié.
* `security-acceptance-test.sh` dépend du déploiement : lancé sans conteneur, il échoue —
  c'est volontaire (un test d'acceptation sans cible n'a pas de sens).

---

## 4. Phase 3 — Production

### 4.1 Objectifs

Durcir l'hôte, injecter les secrets à l'exécution, et vérifier le service **après**
déploiement, là où un attaquant le verrait.

### 4.2 Durcissement de la VM — `scripts/install-phase3.sh`

| Mesure | Détail | Vérification |
|---|---|---|
| Pare-feu `ufw` | SSH autorisé **avant** l'activation ; ordre prouvé par un mode `DRY_RUN=1` | `ufw status numbered` : règle SSH insérée avant l'activation |
| `fail2ban` | prison `sshd`, `maxretry`, `bantime` définis dans `/etc/fail2ban/jail.d/devsecops.local` | `fail2ban-client -t` puis `status sshd` |
| `ignoreip` | `127.0.0.1/8 ::1 10.0.2.2` — **10.0.2.2 est l'adresse NAT de VirtualBox** : ses propres sessions `vagrant ssh` ne peuvent donc jamais être bannies | `fail2ban-client status sshd` montre l'adresse ignorée |
| Mises à jour | `unattended-upgrades` activé pour les correctifs de sécurité | `systemctl is-active` |
| Garde-fous | le script refuse de s'exécuter si une règle SSH n'est pas présente avant l'activation | messages du script |

### 4.3 Secrets

Le conteneur de production reçoit `APP_API_KEY` **à l'exécution**, via
`withCredentials([string(credentialsId: 'app-api-key', ...)])`, écrit dans un fichier
temporaire `0600` utilisé par `--env-file` puis supprimé immédiatement (`trap ... EXIT`).
Le secret n'apparaît ni dans l'image, ni dans le `Jenkinsfile`, ni dans les logs : le
contrôle de configuration n'affiche que « set / unset ».

### 4.4 Contrôles post-déploiement

* **`security-smoke-test.sh` — 13 contrôles** : disponibilité, trois en-têtes,
  `/actuator/health` ouvert, `/actuator/prometheus` sert les métriques JVM, la page de
  découverte `/actuator` **n'annonce que** des endpoints sûrs, `env`/`beans`/`heapdump`
  restent 404, route inconnue en 404, `TRACE` refusé, aucune bannière.
* **`config-safety-check.sh` — 8 contrôles** : conteneur en marche, utilisateur numérique
  non-root, image pas `:latest`, conteneur non privilégié, pas de `network_mode: host`, pas
  de socket Docker monté, `APP_API_KEY` présent et différent du placeholder, ports exposés
  conformes (`22 8080 18080 18081 3000`).

### 4.5 Preuves

| Capture | Contenu |
|---|---|
| 13 | `fail2ban-client status sshd` (prison active) |
| 14 | `ufw status numbered` (SSH autorisé, ordre correct) |
| 15 | `unattended-upgrades` actif |
| 16 | Smoke tests : 13/13 |
| 17 | Configuration safety : 8/8 |
| 18 | Déploiement production avec secret injecté (aucune valeur affichée) |

### 4.6 Limites de la phase

* « Production » est un second conteneur sur la **même** VM : pas d'hôte distant, pas de
  registre d'images, pas de déploiement bleu/vert.
* Pas de TLS : le réseau Vagrant est privé, la terminaison TLS est hors périmètre.

---

## 5. Phase 4 — Opérations

### 5.1 Objectifs

Rendre l'application **observable** et **alertante** : des métriques collectées, un tableau
de bord qui montre l'état réel, et des règles d'alerte qui se déclenchent sur des seuils
justifiés — sans élargir la surface d'administration du service.

### 5.2 Surface Actuator réduite

`application.properties` :

```properties
management.endpoints.web.exposure.include=health,prometheus
management.endpoint.health.show-details=never
management.endpoint.health.show-components=never
```

Seuls `health` et `prometheus` sont exposés. `env`, `beans`, `heapdump`, `threaddump` et
`loggers` restent fermés — et le smoke test échoue **si** la page de découverte les
annonce, ce qui interdit de rouvrir ces endpoints « pour déboguer ».

### 5.3 Pile d'observation

`monitoring/docker-compose.yml`, sur le réseau `devsecops-net` du pipeline :

| Service | Version épinglée | Rôle | Limite mémoire |
|---|---|---|---|
| Prometheus | `prom/prometheus:v2.54.1` | collecte (15 s), règles, rétention 7 j | 512 Mo |
| Alertmanager | `prom/alertmanager:v0.27.0` | routage/groupement des alertes | 128 Mo |
| Grafana | `grafana/grafana:11.2.0` | tableau de bord provisionné | 256 Mo |
| node_exporter | `prom/node-exporter:v1.8.2` | métriques de l'hôte (CPU, mémoire) | 64 Mo |

Trois cibles sont collectées : `devsecops-app:8080/actuator/prometheus`,
`node-exporter:9100` et Prometheus lui-même. L'application est jointe **par nom de
conteneur** sur le réseau Docker, pas par port publié : la collecte ne dépend donc pas de
l'exposition réseau.

### 5.4 Tableau de bord

Tableau `DevSecOps - Application and host` (uid `devsecops-overview`), **provisionné par
fichier** et non cliqué dans l'interface — il existe dès l'installation :

| Panneau | Requête (résumé) |
|---|---|
| Requests per second | `sum(rate(http_server_requests_seconds_count{job="devsecops-app"}[1m]))` |
| p95 latency | `histogram_quantile(0.95, sum(rate(..._bucket[5m])) by (le))` |
| Application up | `up{job="devsecops-app"}` |
| JVM heap used | `sum(jvm_memory_used_bytes{...,area="heap"})` |
| Process CPU | `process_cpu_usage{job="devsecops-app"}` |
| VM memory used | `1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` |

### 5.5 Règles d'alerte (6)

| Alerte | Expression (résumé) | Durée | Gravité |
|---|---|---|---|
| `ApplicationDown` | `up{job="devsecops-app"} == 0` | 1 min | critical |
| `HighErrorRate` | part de 5xx > 5 % sur 5 min | 5 min | warning |
| `SlowResponses` | p95 > 1 s sur 5 min | 5 min | warning |
| `HighHeapUsage` | heap JVM > 350 Mo | 10 min | warning |
| `NodeDown` | `up{job="node"} == 0` | 2 min | critical |
| `HostMemoryHigh` | mémoire VM utilisée > 90 % | 10 min | warning |

Les durées `for` évitent les alertes de scintillement : un pic ponctuel ne réveille
personne. Alertmanager route par `alertname` (`group_wait: 10s`,
`group_interval: 1m`, `repeat_interval: 4h`) vers un destinataire **volontairement
silencieux** : le projet n'a pas de système d'astreinte, et l'alerte est visible dans
Prometheus (`/alerts`) et dans l'interface Alertmanager. Le remplacement par un webhook
réel est documenté dans le fichier, sans URL en clair.

### 5.6 Exposition réseau — seule Grafana est publiée

Prometheus, Alertmanager et node_exporter sont liés à `127.0.0.1` ; Grafana est le seul
service publié sur toutes les interfaces (port 3000). Conséquence directe sur le pare-feu :
`install-phase4.sh` n'ouvre **qu'une seule règle** (`3000/tcp`).

> **Justification (une ligne, pour le rapport) :** seule l'interface Grafana (3000/tcp) est
> publiée hors de la VM ; Prometheus, Alertmanager et node_exporter sont liés à 127.0.0.1 et
> ne sont joignables que depuis la VM et le réseau Docker, ce qui réduit la surface exposée
> et ramène la règle ufw à un seul port.

Ce choix est **contrôlé**, pas seulement documenté : `monitoring-check.sh` vérifie la
liaison de chaque port et échoue si un port d'observation est publié sur toutes les
interfaces (test négatif effectué : un compose publiant `9090:9090` est refusé).

### 5.7 Preuves

| Capture | Contenu |
|---|---|
| 19 | `install-phase4.sh` : images récupérées, trois services prêts |
| 20 | `docker compose ps` : quatre services en marche |
| 21 | Prometheus → Targets : `devsecops-app` **UP** |
| 22 | Tableau de bord Grafana avec courbes réelles |
| 23 | Prometheus `/alerts` : `ApplicationDown` en état *firing* |
| 24 | `monitoring-check.sh` : 14/14 |

**Scénario de démonstration de l'alerte :** supprimer le conteneur applicatif
(`docker rm -f devsecops-app`), attendre environ une minute, montrer `ApplicationDown`
passant de *pending* à *firing* dans Prometheus puis dans Alertmanager, redémarrer le
conteneur, montrer la résolution. C'est exactement ce que fait le `post` du pipeline, qui
supprime les conteneurs applicatifs en fin de build.

### 5.8 Mot de passe Grafana

Généré une seule fois par `install-phase4.sh` dans `monitoring/.env` (permissions `0600`,
ignoré par git), jamais affiché par les scripts, jamais passé en argument de commande :
`monitoring-check.sh` le lit depuis le fichier. Un secret en argument apparaîtrait dans
`ps` et dans la console Jenkins.

### 5.9 Limites de la phase

* La pile a été **validée en configuration** (YAML, JSON du tableau de bord, `docker compose
  config`, étiquettes d'images vérifiées auprès du registre) et ses scripts de contrôle ont
  été exercés contre un Prometheus/Grafana de substitution ; son **exécution réelle**
  (collecte, rendu du tableau de bord, remontée d'alerte) est prouvée sur la VM et doit être
  capturée là-bas.
* Pas de système de pagination : les alertes sont visibles, pas notifiées.
* 4 Go de RAM est la contrainte structurante : ZAP, SonarQube et la pile d'observation ne
  doivent pas tourner en même temps (§7).

---

## 6. Difficultés rencontrées et décisions techniques

Cette section est celle qui distingue un projet exécuté d'un projet recopié : chaque
problème ci-dessous a été rencontré, diagnostiqué et corrigé.

| # | Problème | Diagnostic | Correction |
|---|---|---|---|
| 1 | Route inconnue renvoyant **500** au lieu de 404 | le gestionnaire d'erreurs générique interceptait aussi `NoHandlerFoundException` | gestion séparée : 404 pour route inconnue, 500 sans détail pour erreur interne |
| 2 | `dependency-check-maven` 13.x refuse de tourner | Maven **3.6.3** est trop ancien pour ce plugin | utilisation du **CLI** Dependency-Check 13.0.0, indépendant de Maven |
| 3 | Téléchargement NVD très lent / limité | quota NVD sans clé API | identifiant Jenkins `nvd-api-key` ; cache local réutilisé |
| 4 | `ufw` peut couper l'accès SSH | activation avant la règle SSH | règle SSH insérée **avant** `enable`, ordre prouvé par un mode `DRY_RUN` |
| 5 | Risque de s'auto-bannir avec fail2ban | adresse NAT VirtualBox `10.0.2.2` vue comme source des sessions `vagrant ssh` | `10.0.2.2` ajoutée à `ignoreip` |
| 6 | Le smoke test échouait sur `/actuator` | `/actuator` est la page de **découverte** : elle répond 200, ce n'est pas une fuite | l'assertion porte sur son **contenu** : elle ne doit annoncer aucun endpoint sensible |
| 7 | `/actuator/prometheus` introuvable dans les tests MockMvc | dans un contexte de test, l'export de métriques est désactivé (`management.defaults.metrics.export.enabled`), donc l'endpoint n'est jamais enregistré | assertion déplacée vers une **exécution réelle** du service — preuve plus forte que le contexte de test |
| 8 | Échec intermittent du smoke test alors que l'application servait les métriques | `curl … \| grep -q` : `grep` ferme le tube au premier résultat, `curl` meurt de SIGPIPE (141) et `pipefail` transforme un succès en échec | corps de réponse capturé **avant** le filtrage (5 exécutions consécutives stables) |
| 9 | Le `post` supprimait le réseau Docker utilisé par la pile d'observation | `docker network rm` cassait la cible Prometheus | le réseau n'est supprimé que si aucun conteneur n'y est attaché |
| 10 | 4 Go de RAM insuffisants pour tout | Jenkins + ZAP + SonarQube + pile dépassent la RAM | SonarQube optionnel et **en dernier**, ZAP en baseline, limites mémoire sur les conteneurs, OSSEC écarté au profit de fail2ban |
| 12 | Le stage Dependency-Check échoue **avant tout scan** : `Couldn't find any executable in "null"` | le step `dependencyCheck` du plugin Jenkins exige un outil configuré (Global Tool Configuration) avec une installation valide ; l'enregistrement était vide, et le CLI installé par nos scripts n'était pas utilisé | le stage appelle directement le CLI `/opt/dependency-check/bin/dependency-check.sh` (installé et vérifié par `scripts/install-dependency-check.sh`), avec `--failOnCVSS 9` comme porte et la clé NVD passée par un fichier de propriétés `0600` |
| 11 | 9 vulnérabilités critiques dans nos propres dépendances (scan lancé hors Jenkins) | un `trivy` exécuté sur le poste de développement remonte 7 CVE Tomcat (10.1.31) et 1 CVE `spring-webmvc` 6.1.14, corrigées en 10.1.55+/7.0.9 ; Boot 3.3.5 est hors support | montée en **Spring Boot 4.1.2** (Spring 7.0.10, Tomcat 11.0.27) ; `@AutoConfigureMockMvc` déplacé dans un module dédié ; **résultat à confirmer par le build Jenkins : `[À REMPLIR: résultat réel du scan]`** |

> **Provenance du point 11.** Le chiffre de 9 CVE critiques ne vient pas de Jenkins : il
> vient d'un scan `trivy` lancé sur le poste de développement où le pipeline a été écrit,
> avant la montée de version. Jenkins n'a encore produit aucun résultat Trivy ni
> Dependency-Check ; les seuls chiffres à citer sont donc ceux du build de la VM.

---

## 7. Pipeline consolidé

`Jenkinsfile` sur `devsecops-final` : **21 stages**, **14 paramètres booléens**. La
référence complète (paramètres, portes, artefacts, ordre, dépannage) est dans
[`docs/pipeline-overview.md`](pipeline-overview.md) et l'inventaire des outils dans
[`docs/tools-table.md`](tools-table.md).

| # | Stage | Phase | Preuve produite |
|---|---|---|---|
| 1 | Checkout | 1 | bon commit |
| 2 | Preflight (tool checks) | 1 | outils présents ou message clair |
| 3 | Build | 1 | compilation |
| 4 | Unit and security tests | 1 | 10 tests, rapport JUnit |
| 5 | Secrets scan (Gitleaks) | 1 | `gitleaks-report.json` |
| 6 | Dependency scan (OWASP Dependency-Check) | 1 | rapport HTML/XML, porte CVSS ≥ 9 |
| 7 | Dependency scan (Trivy fs) | 1 | `trivy-fs-resolved-report.*`, SBOM CycloneDX, porte CRITIQUE, sans clé API |
| 8 | Dockerfile lint (hadolint) | 1 | `hadolint-report.txt` |
| 9 | Container image (build) | 2 | identifiant d'image |
| 10 | Container scan (Trivy) | 2 | `trivy-report.*` |
| 11 | Deploy application container | 2 | service joignable (18080) |
| 12 | DAST (OWASP ZAP baseline) | 2 | `zap-report.html/json` |
| 13 | Security acceptance tests | 2 | `acceptance-report.txt` (11) |
| 14 | Infrastructure test (VM) | 2 | `infra-report.txt` |
| 15 | Compliance check (policy) | 2 | `compliance-report.txt` (9) |
| 16 | Deploy production container | 3 | service joignable (18081), secret injecté |
| 17 | Security smoke tests | 3 | `smoke-report.txt` (13) |
| 18 | Configuration safety check | 3 | `config-safety-report.txt` (8) |
| 19 | Operations: monitoring stack | 4 | pile démarrée |
| 20 | Operations: metrics and alerts check | 4 | `monitoring-report.txt` (14) |
| 21 | SAST (SonarQube) | 1 | *quality gate* (optionnel) |

**Paramètres (14).** Tout ce qui est lourd, optionnel ou dépend d'un identifiant est un
paramètre désactivé par défaut, pour qu'un build ordinaire reste sûr sur 4 Go :

| Paramètre | Défaut | Effet |
|---|---|---|
| `RUN_SONAR` | désactivé | analyse SAST et *quality gate* SonarQube (≈ 2 Go) |
| `RUN_DEPENDENCY_CHECK` | activé | stage Dependency-Check (flux NVD, clé `nvd-api-key`) ; à désactiver **uniquement** si la clé est refusée |
| `RUN_TRIVY_FS` | activé | scan Trivy des dépendances résolues, sans clé API ni Docker |
| `BUILD_IMAGE` | activé | construit `devsecops-demo:ci` |
| `TRIVY_SCAN` | activé | scan d'image, échec sur CRITIQUE |
| `DEPLOY_CONTAINER` | activé | conteneur applicatif sur 18080 |
| `ZAP_SCAN` | activé | DAST baseline (≈ 1 Go) |
| `ACCEPTANCE_TESTS` | activé | 11 contrôles d'acceptation |
| `INFRA_TEST` | activé | état de la VM |
| `COMPLIANCE_CHECK` | activé | 9 contrôles de politique |
| `PROD_DEPLOY` | **désactivé** | conteneur de production sur 18081 avec secret injecté |
| `SECURITY_SMOKE` | activé | 13 contrôles après déploiement |
| `CONFIG_SAFETY` | activé | 8 contrôles de configuration |
| `MONITORING` | **désactivé** | démarre la pile et exécute les 14 contrôles d'observation |

Les dépendances entre paramètres (par exemple `ZAP_SCAN` sans `DEPLOY_CONTAINER`) et le
dépannage stage par stage sont détaillés dans
[`docs/pipeline-overview.md`](pipeline-overview.md).

**Ordre et contrainte mémoire.** Les scans précèdent la construction de l'image (un secret
coûte moins cher à trouver avant). Le déploiement précède le DAST et les tests
d'acceptation (ils ont besoin d'un service vivant). SonarQube est **en dernier** pour ne
jamais coïncider avec ZAP. Budget approximatif : Jenkins ≈ 1 Go, application ≈ 300 Mo,
ZAP ≈ 1 Go, SonarQube ≈ 2 Go, pile d'observation ≈ 960 Mo.

**Portes de dépendances.** Les deux scans restent à la même exigence : CRITIQUE / CVSS ≥ 9.
Si la clé NVD est refusée (`Invalid apiKey`), `RUN_DEPENDENCY_CHECK` se décoche et le scan
Trivy continue de couvrir les mêmes dépendances : le stage est *sauté*, jamais abaissé.

**Contrôle de configuration.** Le stage s'exécute par défaut : il inspecte le conteneur de
production quand il existe, sinon celui d'acceptation — l'assertion sur le secret injecté ne
s'applique alors qu'à la production et s'affiche comme information — et il échoue s'il n'y a
aucun conteneur à inspecter.

**Nettoyage.** Les conteneurs applicatifs sont supprimés à chaque build (succès ou échec) ;
la pile d'observation reste en place pour la démonstration et se retire avec
`docker compose -f monitoring/docker-compose.yml down`.

---

## 8. Limites générales et travaux futurs

1. **Pas de CD réel** : « production » est un second conteneur sur la même VM ; il n'y a ni
   registre d'images, ni hôte distant, ni stratégie de retour arrière.
2. **Pas de TLS** : le réseau Vagrant est privé ; une terminaison TLS serait la première
   brique à ajouter.
3. **Pas de notification d'alerte** : règles réelles, destinataire silencieux ; un webhook
   (Slack/Teams) est prévu par conception, jamais commité.
4. **Versions apt non épinglées** : Docker, Trivy et les paquets de la Phase 3 viennent de
   dépôts signés ; les versions réellement installées sont affichées par `infra-check.sh`.
5. **Couverture partielle du DAST** : baseline non authentifiée ; un scan complet demanderait
   plus de RAM et des comptes de test.
6. **Travaux futurs** : signature d'image (cosign), SBOM (CycloneDX), politiques OPA,
   agent de build rootless, tableau de bord SLO.

---

## 9. Conclusion

Les quatre phases forment une chaîne continue : le code est contraint dès l'écriture
(Phase 1), l'image et le service sont acceptés sur preuve (Phase 2), l'hôte est durci et le
service vérifié après déploiement (Phase 3), l'ensemble est observé et alerté (Phase 4).
Chaque exigence annoncée est adossée à un stage bloquant et à un artefact archivé : le
pipeline ne « dit » pas que l'application est sûre, il le démontre — et il échoue quand ce
n'est plus vrai.

Les limites sont explicites plutôt que masquées : pas de CD réel, pas de TLS, pas de
pagination, versions apt non épinglées. Ce sont des choix assumés liés à un environnement de
4 Go et à un périmètre de projet scolaire, et chacun est documenté à l'endroit où il
s'applique.

---

## Annexe A — Commandes utiles (VM)

```bash
git fetch origin && git switch devsecops-final && git pull --ff-only
sudo bash scripts/install-tools.sh
sudo bash scripts/install-dependency-check.sh
sudo bash scripts/install-phase2.sh
sudo bash scripts/install-phase3.sh
sudo bash scripts/install-phase4.sh
bash scripts/infra-check.sh
```

## Annexe B — Fichiers de preuve

Tous les rapports sont archivés par build sous `reports/` (voir §7) et consultables dans
Jenkins (artefacts + vues JUnit, HTML Publisher). Les captures attendues et la commande qui
les produit sont listées dans [`docs/captures/README.md`](captures/README.md).

Les contrôles exécutés dans l'**environnement de développement** (build, 10 tests, gitleaks,
hadolint, shellcheck, validation Compose/YAML/JSON, smoke 13/13, acceptance 11/11,
monitoring 14/14, compliance 9/9, tests négatifs) sont consignés dans
[`docs/verification-here.md`](verification-here.md), avec la liste de ce qui ne peut être
prouvé que sur la VM. Ce fichier décrit un poste de développement, **pas la VM ni Jenkins** :
les résultats de scan cités dans ce rapport restent marqués
`[À REMPLIR: résultat réel du scan]` jusqu'à ce que le build Jenkins les produise.
