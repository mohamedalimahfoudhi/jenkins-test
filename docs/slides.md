# Support de soutenance — 14 diapositives

Plan de présentation calibré pour **15 minutes** (≈ 1 min par diapositive) + 5 minutes de
questions. Chaque diapositive indique ce qui doit être **à l'écran** et ce qui doit être
**dit**. Les captures renvoient à [`docs/captures/README.md`](captures/README.md).

Règle de la soutenance : montrer une preuve, pas une intention. Une affirmation sans
capture ni stage visible derrière elle ne doit pas être prononcée.

---

### 1. Titre

**À l'écran :** nom du projet, application Spring Boot, quatre phases, votre nom, date.

**À dire :** « Sécuriser une API Spring Boot de l'écriture du code jusqu'à l'exploitation,
avec un pipeline Jenkins qui prouve chaque exigence. »

---

### 2. Contexte et démarche

**À l'écran :** les 4 phases, la VM (Ubuntu 22.04, 4 Go, Jenkins 2.580.2), les branches.

**À dire :** trois règles tenues pendant tout le projet — aucune mesure sans contrôle,
aucun secret dans le dépôt, aucune version inventée. Une branche par phase, `main` jamais
touchée.

**Diapo clé :** c'est ici que vous annoncez que tout ce qui suit est vérifiable.

---

### 3. Phase 1 — Développement

**À l'écran :** capture 1 (pipeline vert) + tableau STRIDE condensé.

**À dire :** modèle de menace STRIDE, validation des entrées, erreurs neutres, en-têtes de
sécurité, hook pre-commit doublé côté serveur (un hook se contourne avec `--no-verify`).

---

### 4. Phase 1 — Les outils de preuve

**À l'écran :** captures 3, 4, 5, 6 (10 tests, gitleaks, Dependency-Check, hadolint).

**À dire :** chaque outil a une porte explicite : gitleaks bloque au premier secret,
Dependency-Check seulement sur CVSS ≥ 9, le scan Trivy des dépendances échoue sur CRITIQUE
sans avoir besoin de clé API, hadolint bloque sur toute alerte. Une porte qui ne bloque
jamais n'est pas une sécurité.

---

### 5. Phase 2 — Acceptation

**À l'écran :** capture 12 (7 stages) + tableau stages/portes.

**À dire :** l'acceptation porte sur l'**image** et sur le **service exécuté**, pas sur le
code. Trivy sur l'image, ZAP baseline sur le conteneur, 11 tests d'acceptation, 9 contrôles
de conformité.

---

### 6. Phase 2 — Résultats

**À l'écran :** captures 7, 8, 9, 10.

**À dire :** 11/11 acceptation et 9/9 conformité (résultats des scripts) ; pour les CVE et
pour ZAP, annoncer le résultat réel du build : `[À REMPLIR: résultat réel du scan]`.
Mentionner que ZAP est en baseline : choix assumé lié aux 4 Go, pas une économie déguisée.

---

### 7. Phase 3 — Durcissement de la VM

**À l'écran :** captures 13, 14, 15.

**À dire :** `ufw` avec SSH autorisé **avant** activation (ordre vérifié en mode dry-run),
fail2ban avec `10.0.2.2` dans `ignoreip` — c'est l'adresse NAT de VirtualBox, donc mes
propres sessions `vagrant ssh` ne peuvent pas me bannir — et `unattended-upgrades` pour les
correctifs.

**Question probable :** « pourquoi fail2ban et pas OSSEC ? » → OSSEC exige un manager et
~200 Mo de RAM sur une machine qui fait déjà tourner Jenkins ; fail2ban couvre la menace
réelle (force brute SSH) avec une prison.

---

### 8. Phase 3 — Secrets et contrôles post-déploiement

**À l'écran :** captures 16, 17, 18.

**À dire :** `APP_API_KEY` injectée à l'exécution via un identifiant Jenkins, écrite dans un
fichier `0600` puis supprimée (`trap`) ; le contrôle n'affiche que « set/unset ». 13
contrôles de fumée, 8 contrôles de configuration.

---

### 9. Phase 4 — Observer

**À l'écran :** capture 22 (tableau de bord Grafana).

**À dire :** seulement `health` et `prometheus` sont exposés ; la page de découverte ne doit
annoncer aucun endpoint sensible, et le smoke test échoue si c'est le cas. Six panneaux :
débit, p95, disponibilité, heap, CPU, mémoire VM.

---

### 10. Phase 4 — Alerter

**À l'écran :** capture 23 (`ApplicationDown` firing) + tableau des 6 règles.

**À dire :** les seuils et les durées `for` évitent les alertes de scintillement. Alertmanager
groupe et route ; le destinataire est volontairement silencieux (pas d'astreinte dans ce
projet), l'alerte reste visible dans Prometheus et Alertmanager.

---

### 11. Phase 4 — Réduire la surface

**À l'écran :** extrait du compose (3 ports en `127.0.0.1`, Grafana en `0.0.0.0`) + la phrase
de justification.

**À dire :** seule Grafana est publiée hors de la VM ; Prometheus, Alertmanager et
node_exporter ne sont joignables que depuis la VM et le réseau Docker, donc une seule règle
ufw. Et c'est **contrôlé** : `monitoring-check.sh` échoue si un port d'observation est
republié.

---

### 12. Le pipeline consolidé

**À l'écran :** capture 25 (21 stages) + les 14 paramètres.

**À dire :** un seul pipeline, quatre phases, des paramètres pour tout ce qui est lourd ou
optionnel (SonarQube, déploiement production, monitoring). L'ordre est contraint par la
mémoire : SonarQube en dernier pour ne jamais coïncider avec ZAP. Si la clé NVD est refusée,
`RUN_DEPENDENCY_CHECK` se décoche — le stage est sauté, pas abaissé — et le scan Trivy des
dépendances continue.

---

### 13. Difficultés réelles

**À l'écran :** les 5 lignes les plus parlantes du tableau §6 du rapport.

**À dire (choisir trois) :**
1. route inconnue en 500 → séparation 404/500 ;
2. Maven 3.6.3 incompatible avec le plugin Dependency-Check 13 → CLI ;
3. `/actuator` répond 200 : ce n'est pas une fuite, l'assertion porte sur son contenu ;
4. échec intermittent du smoke test → SIGPIPE avec `curl | grep -q` + `pipefail` ;
5. le `post` supprimait le réseau Docker de la pile d'observation → corrigé.

Ces cinq points montrent un projet **exécuté**, pas recopié.

---

### 14. Limites et conclusion

**À l'écran :** liste courte des limites + une phrase de conclusion.

**À dire :** pas de CD réel (production = second conteneur local), pas de TLS, pas de
pagination, versions apt non épinglées, DAST non authentifié. Conclusion : le pipeline ne
« dit » pas que l'application est sûre, il le démontre et échoue quand ce n'est plus vrai.

---

## Questions probables et réponses courtes

| Question | Réponse |
|---|---|
| Pourquoi `main` n'est jamais touchée ? | chaque phase est une branche livrable ; `devsecops-final` est la consolidation, `main` reste le dépôt d'origine |
| Pourquoi ne pas pousser l'image dans un registre ? | hors périmètre : une seule VM, pas de registre ; c'est écrit dans les limites |
| Un secret est-il passé en argument quelque part ? | non : identifiants Jenkins, fichier `0600`, et le mot de passe Grafana est lu depuis `monitoring/.env` |
| Pourquoi Dependency-Check en CLI ? | Maven 3.6.3 ne peut pas exécuter le plugin 13.x ; le CLI produit le même rapport |
| Comment prouvez-vous que le pare-feu est correct ? | `ufw status numbered` + `config-safety-check.sh` qui contrôle les ports réellement exposés |
| Que se passe-t-il si Prometheus tombe ? | `NodeDown` ne couvre pas Prometheus ; Prometheus se scrape lui-même, mais une panne de Prometheus n'alerte pas → limite connue, à mentionner si on vous la pose |
| Pourquoi 4 Go suffisent-ils ? | ZAP et SonarQube sont optionnels et jamais simultanés ; limites mémoire sur les conteneurs ; OSSEC écarté |
