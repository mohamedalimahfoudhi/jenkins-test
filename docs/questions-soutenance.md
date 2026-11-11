# Questions de soutenance — réponses courtes et ancrées dans ce projet

Chaque réponse renvoie à un stage, un script ou un fichier du dépôt. Si une question porte sur
un chiffre de scan, la réponse est « le résultat du build », jamais un chiffre mémorisé.

---

## 1. Concepts

| Question | Réponse |
|---|---|
| DevOps vs DevSecOps ? | DevOps raccourcit la boucle code → production ; DevSecOps y ajoute des contrôles **bloquants** à chaque étape, pas un audit à la fin. Ici : gitleaks, Dependency-Check, Trivy, hadolint en Phase 1 ; ZAP et tests d'acceptation en Phase 2 ; smoke tests en Phase 3 ; métriques en Phase 4. |
| CI/CD ? | Intégration continue : chaque commit est compilé, testé et scanné (stages 1–8). Livraison continue : l'artefact validé est déployé automatiquement (stages 9–11). Pas de déploiement continu ici : la « production » est un second conteneur local, c'est une limite assumée. |
| Pourquoi un pipeline unique au lieu de quatre ? | Les phases sont des **propriétés** de la livraison, pas des projets séparés. Un seul `Jenkinsfile` de 21 stages évite de rejouer la même configuration quatre fois et rend les dépendances d'ordre explicites. Les branches `devsecops-phase1..4` restent l'historique de construction. |
| SAST / DAST / SCA ? | SAST : analyse du code sans l'exécuter (SonarQube, optionnel). DAST : attaque d'un service en fonctionnement (ZAP baseline). SCA : inventaire des dépendances et de leurs CVE (Dependency-Check, Trivy). |
| Qu'est-ce qu'une porte (*quality gate*) ? | Une condition qui **échoue le build**. Une mesure qui ne bloque jamais n'est pas une sécurité : c'est un rapport. Exemples : secret détecté, CVSS ≥ 9, CVE CRITIQUE dans l'image, règle ZAP en `FAIL`, test d'acceptation raté. |
| Shift left ? | Les contrôles les moins chers sont le plus à gauche : un secret trouvé avant l'image coûte une minute, le même secret dans une image publiée coûte une rotation de clé. C'est pourquoi les scans précèdent la construction de l'image. |

## 2. Jenkins

| Question | Réponse |
|---|---|
| Combien de stages / paramètres ? | 21 stages, 14 paramètres booléens. Les noms de stages sont stables : le rapport, les captures et les scripts les citent par leur nom. |
| À quoi servent les paramètres ? | Rendre optionnel tout ce qui est lourd (`ZAP_SCAN`, `MONITORING`, `RUN_SONAR`), risqué (`PROD_DEPLOY`) ou dépendant d'une clé (`RUN_DEPENDENCY_CHECK`). Un build par défaut reste sûr sur 4 Go. |
| Désactiver un stage, est-ce l'affaiblir ? | Non : la porte garde son seuil quand le stage tourne, et le stage est **sauté**, pas adouci. Preuve : `RUN_DEPENDENCY_CHECK=off` laisse `--failOnCVSS 9` intact, et le scan Trivy des dépendances couvre le même périmètre sans clé. |
| `Preflight` sert à quoi ? | Échouer une fois, avec le bon message, quand un outil manque — au lieu de mourir au milieu d'un stage de sécurité. Il ne vérifie que les outils que **ce** build va utiliser (docker seulement si un stage Docker tourne, CLI Dependency-Check seulement si ce stage est actif). |
| Pourquoi SonarQube en dernier ? | C'est le plus gros consommateur de mémoire (≈ 2 Go avec PostgreSQL). En dernier, il ne coïncide jamais avec ZAP ; sur 4 Go, les deux ensemble font swapper la VM. |
| Déclaratif vs scripté ? | Déclaratif : la structure (stages, `when`, `post`) est lisible et les `post` garantissent l'archivage même en échec. Le shell fait le travail réel, ce qui rend chaque contrôle rejouable hors Jenkins. |
| Que fait `post { always }` ? | Supprime les conteneurs applicatifs (un build ne doit jamais tester un conteneur périmé) et conserve le réseau Docker tant que la pile d'observation y est attachée — sinon Prometheus perd sa cible. |

## 3. Scans de dépendances

| Question | Réponse |
|---|---|
| Dependency-Check : comment est-il intégré ? | Via son **CLI** `/opt/dependency-check`, installé par `scripts/install-dependency-check.sh`, avec `--failOnCVSS 9`. Pas via le plugin Jenkins : celui-ci a échoué sur la VM avec `Couldn't find any executable in "null"` (outil non résolu), ce qui arrêtait le build avant tout scan. |
| Où passe la clé NVD ? | Dans un identifiant Jenkins `nvd-api-key`, puis dans un fichier de propriétés `0600` supprimé par `trap`. Jamais en argument : Jenkins exécute `sh` avec `-x`, donc un argument finirait dans la console. |
| Et si la clé est invalide ? | `RUN_DEPENDENCY_CHECK` se décoche : le stage est sauté, le seuil est inchangé, et le scan Trivy continue. Aucun résultat n'est inventé. |
| Pourquoi deux scans de dépendances ? | Dependency-Check interroge le flux NVD (CVE publiées, CPE) ; Trivy compare les mêmes dépendances à sa propre base, sans clé ni quota. Complémentaires : les deux bases ne publient pas le même jour. |
| Pourquoi un SBOM CycloneDX ? | `trivy fs .` ne lit que `pom.xml`, où `spring-boot-starter-parent` fournit les versions : il ne trouve donc rien, quel que soit le contenu du classpath (vérifié : « language-specific files num=0 », et il n'ouvre pas les jars). Le pipeline résout donc les dépendances avec Maven, les convertit en SBOM CycloneDX, et scanne ce SBOM. |
| Qu'est-ce qui empêche un faux « 0 vulnérabilité » ? | `scripts/generate-sbom.py` sort en erreur si la liste est vide, et le stage échoue s'il ne trouve aucun jar : on ne peut pas certifier un périmètre qu'on n'a pas lu. |
| Un SBOM, à quoi ça sert d'autre ? | Inventaire livrable avec l'application (traçabilité, réponse à incident), et format d'échange : le même fichier peut être scanné par un autre outil sans reconstruire le projet. |

## 4. Gitleaks, hadolint, Docker

| Question | Réponse |
|---|---|
| Gitleaks : quoi et où ? | Détection de secrets par expressions et entropie. Deux barrières : hook `pre-commit` (`gitleaks protect`) pour le poste, et stage serveur sur **tout l'historique** — un hook se contourne avec `--no-verify`, pas le stage. |
| Un secret déjà commité ? | Le scan porte sur l'historique complet : il ressort même si le fichier a été supprimé depuis. La correction est une rotation de clé, pas un `git rm`. |
| hadolint ? | Lint du Dockerfile : image non épinglée, `latest`, root, `ADD`, `curl | sh`. Une alerte échoue le stage. |
| Sécurité de l'image ? | Base épinglée, utilisateur numérique non-root (`USER 10001:10001`), pas d'outils de build dans l'image finale, `HEALTHCHECK`, pas de secret en `ENV`. Vérifié deux fois : hadolint (statique) et `config-safety-check.sh` (conteneur réel). |
| App tournant en root : le vrai risque ? | Une évasion de l'application donne root **dans** le conteneur, et combinée à un montage ou à une faille du noyau, root sur l'hôte. Non-root réduit la surface, il ne remplace pas les namespaces. |
| Pourquoi le groupe `docker` est-il sensible ? | Un membre du groupe `docker` peut lancer un conteneur privilégié et monter `/` : c'est équivalent à root. Nécessaire ici pour que Jenkins construise des images ; l'alternative professionnelle est un agent rootless. |

## 5. DAST et tests

| Question | Réponse |
|---|---|
| ZAP baseline ou complet ? | Baseline : passif + règles légères, quelques minutes, compatible 4 Go. Un scan complet demande une authentification et beaucoup plus de temps. Choix assumé, pas une économie déguisée. |
| Que teste ZAP ici ? | Le conteneur applicatif, joint **par nom** sur le réseau Docker (`http://devsecops-app:8080/hello`) : le scan ne dépend donc pas du port publié. Une règle `FAIL` échoue le stage ; `-I` ignore les avertissements. |
| Tests d'acceptation vs tests unitaires ? | Unitaires (10) : comportement du code en mémoire. Acceptation (11) : contrat de sécurité du **service déployé** — codes HTTP, en-têtes, refus d'entrée invalide, absence de fuite dans les erreurs, 404 sur route inconnue, `TRACE` refusé. |
| Comment prouvez-vous qu'une erreur ne fuit pas ? | `/api/boom` renvoie 500 avec un corps neutre ; l'assertion cherche `Exception`, `com.example` ou une trace Java dans le corps. Le détail reste dans les logs serveur. |
| Et si aucun conteneur ne tourne ? | Les tests échouent : un test d'acceptation sans cible n'a aucun sens. C'est volontaire, et documenté. |

## 6. Secrets et production

| Question | Réponse |
|---|---|
| Comment le secret de production est-il injecté ? | `withCredentials` → fichier temporaire `0600` → `--env-file` → suppression par `trap`. Le secret n'est ni dans l'image, ni dans le `Jenkinsfile`, ni dans la console : le contrôle de configuration n'affiche que « set / unset ». |
| Pourquoi pas Docker secrets ? | Ils exigent Swarm. Sur un seul hôte, le socket Docker est déjà équivalent à root : un fichier `0600` supprimé immédiatement est l'option honnête, et c'est écrit dans les limites. |
| Le mot de passe Grafana ? | Généré une fois dans `monitoring/.env` (`0600`, ignoré par git), lu par `monitoring-check.sh`. Jamais en argument de commande, jamais affiché. |
| Comment vérifier que le secret est bien là ? | `config-safety-check.sh` vérifie sa présence et refuse la valeur d'exemple, sans imprimer la valeur (seulement sa longueur). |

## 7. Observation

| Question | Réponse |
|---|---|
| Prometheus ? | Collecte par *pull* toutes les 15 s sur trois cibles : `devsecops-app:8080/actuator/prometheus`, `node-exporter:9100`, Prometheus lui-même. Rétention 7 jours. |
| Pourquoi Micrometer / Actuator ? | Micrometer expose les métriques JVM/HTTP au format Prometheus ; Actuator les publie sur un endpoint. La surface est réduite à `health` et `prometheus` : `env`, `beans`, `heapdump` renvoient 404, et le smoke test échoue si la page de découverte les annonce. |
| Grafana ? | Tableau de bord **provisionné par fichier** (uid `devsecops-overview`, 6 panneaux) : il existe dès l'installation, sans clic manuel. Reproductible. |
| Alertmanager ? | Reçoit les alertes, groupe et route (`group_wait` 10 s, `repeat_interval` 4 h) vers un destinataire volontairement silencieux : pas d'astreinte dans un projet scolaire, mais l'alerte est visible dans Prometheus et Alertmanager. |
| Scintillement des alertes ? | Chaque règle a un `for` (1 à 10 min) : un pic ponctuel ne déclenche rien. |
| Une panne de Prometheus ? | Elle n'alerte pas (Prometheus ne peut pas signaler sa propre mort). Limite connue, à mentionner si la question est posée : la parade est un Prometheus externe ou un *dead man's switch* Alertmanager. |
| Pourquoi seuls 9090/9093/9100 sont-ils en 127.0.0.1 ? | Seule l'interface Grafana (3000) est publiée hors de la VM ; les autres ne sont joignables que depuis la VM et le réseau Docker. Conséquence : **une seule** règle ufw. Et c'est contrôlé : `monitoring-check.sh` échoue si un port d'observation est republié. |

## 8. Durcissement de la VM

| Question | Réponse |
|---|---|
| Ordre ufw / SSH ? | La règle SSH est insérée **avant** `ufw enable`, et un mode `DRY_RUN=1` le prouve : s'activer d'abord couperait la session en cours. |
| fail2ban et `10.0.2.2` ? | `10.0.2.2` est l'adresse NAT de VirtualBox : les sessions `vagrant ssh` en viennent. L'ajouter à `ignoreip` évite de s'auto-bannir pendant la démonstration. |
| Pourquoi fail2ban et pas OSSEC ? | OSSEC exige un manager et ~200 Mo de RAM sur une machine qui fait déjà tourner Jenkins. fail2ban couvre la menace réelle (force brute SSH) avec une prison. |
| Mises à jour ? | `unattended-upgrades` activé : les correctifs de sécurité s'appliquent sans intervention, ce qui contredit partiellement l'épinglage strict des versions — c'est un arbitrage explicite. |

## 9. Incidents réels (les meilleures réponses en soutenance)

| Incident | Cause | Correction |
|---|---|---|
| Route inconnue en **500** | le gestionnaire d'erreurs générique interceptait aussi `NoHandlerFoundException` | 404 pour route inconnue, 500 sans détail pour erreur interne |
| Smoke test intermittent | `curl … \| grep -q` : `grep` ferme le tube au premier résultat, `curl` meurt de SIGPIPE (141), `pipefail` transforme un succès en échec | corps de réponse capturé avant filtrage, 5 exécutions stables |
| `/actuator` asserté en 404 | c'est la page de découverte : elle répond 200 | l'assertion porte sur son **contenu** (aucun endpoint sensible annoncé) |
| `post` cassait la pile d'observation | `docker network rm` alors que Prometheus y était attaché | suppression seulement si aucun conteneur n'est attaché |
| Plugin Dependency-Check : `Couldn't find any executable in "null"` | `odcInstallation` pointait un outil non résolu ; le build s'arrêtait avant tout scan | appel direct du CLI installé par nos scripts, `--failOnCVSS 9` conservé |
| `unzip` absent → installation Dependency-Check cassée | `python3 -m zipfile` ne restitue pas le bit exécutable, et le test de mise en page utilisait `-x` | `unzip` installé si possible, test en `-f`, puis `chmod +x` |
| `trivy fs .` renvoyait « 0 vulnérabilité » | il ne lit que `pom.xml` (versions gérées par le parent) et n'ouvre pas les jars | résolution Maven + SBOM CycloneDX + `trivy sbom`, échec si la liste est vide |
| 9 CVE critiques dans nos dépendances | Spring Boot 3.3.5 (Tomcat 10.1.31, spring-webmvc 6.1.14) | montée en 4.1.2 (Spring 7.0.10, Tomcat 11.0.27) ; la porte n'a pas été abaissée |

## 10. Limites à annoncer soi-même

Pas de CD réel (production = second conteneur local) · pas de TLS · pas de registre d'images ·
pas de pagination d'alerte · DAST non authentifié · versions apt non épinglées (dépôts signés)
· « production » sur le même hôte que Jenkins.
