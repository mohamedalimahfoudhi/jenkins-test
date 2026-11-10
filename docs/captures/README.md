# Captures à produire sur la VM

Chaque capture du rapport final est référencée par un numéro. Nommez les fichiers
exactement comme ci-dessous et déposez-les dans ce dossier : les liens du rapport
(`docs/rapport-final.md`) fonctionneront sans modification.

Une capture ne vaut que si on voit **la commande (ou le stage) et son résultat** dans la
même image. Élargissez la fenêtre, agrandissez la police du terminal, et évitez de
capturer un écran vide.

| # | Fichier attendu | Où / quoi capturer | Commande ou écran | Résultat attendu |
|---|---|---|---|---|
| 1 | `01-pipeline-phase1.png` | Jenkins → build Phase 1 → *Pipeline Steps* ou vue des stages | build vert | stages Build, Tests, Secrets, Dependency, hadolint visibles |
| 2 | `02-precommit-bloque.png` | terminal du poste de travail | `git commit` avec un faux secret dans un fichier | commit refusé, message gitleaks |
| 3 | `03-tests-unitaires.png` | Jenkins → vue *Tests* du build | stage *Unit and security tests* | 10 tests, 0 échec |
| 4 | `04-gitleaks.png` | artefact `reports/gitleaks-report.json` ou log du stage | stage *Secrets scan* | aucune fuite (`[]` ou absence de finding) |
| 5 | `05-dependency-check.png` | Jenkins → lien « Dependency-Check report » | build | rapport HTML, 0 vulnérabilité critique |
| 6 | `06-hadolint.png` | artefact `reports/hadolint-report.txt` | build | fichier vide / aucune alerte |
| 7 | `07-acceptance-11.png` | terminal VM ou log du stage | `BASE_URL=http://127.0.0.1:18080 bash scripts/security-acceptance-test.sh` | `Result: 11 passed, 0 failed` |
| 8 | `08-zap.png` | Jenkins → lien « OWASP ZAP baseline report » | build | rapport HTML, pas de FAIL |
| 9 | `09-trivy.png` | artefact `reports/trivy-report.txt` | build | aucune CVE CRITICAL |
| 10 | `10-compliance-9.png` | log du stage *Compliance check* | build | `Result: 9 passed, 0 failed` |
| 11 | `11-infra-check.png` | terminal VM | `bash scripts/infra-check.sh` | sections outils / Docker / pare-feu |
| 12 | `12-pipeline-phase2.png` | Jenkins → vue des stages | build avec image + ZAP | 7 stages de la phase 2 verts |
| 13 | `13-fail2ban.png` | terminal VM | `sudo fail2ban-client status sshd` | prison active, adresses ignorées dont `10.0.2.2` |
| 14 | `14-ufw-ordre.png` | terminal VM | `sudo ufw status numbered` | règle SSH présente, pare-feu actif |
| 15 | `15-unattended-upgrades.png` | terminal VM | `systemctl is-active unattended-upgrades` | `active` |
| 16 | `16-smoke-13.png` | terminal VM ou log du stage | `BASE_URL=http://127.0.0.1:18081 bash scripts/security-smoke-test.sh` | `Result: 13 passed, 0 failed` |
| 17 | `17-config-safety-8.png` | terminal VM | `CONTAINER=devsecops-prod bash scripts/config-safety-check.sh` | `Result: 8 passed, 0 failed` |
| 18 | `18-deploiement-prod.png` | Jenkins → log du stage *Deploy production container* | build avec `PROD_DEPLOY` | « production container ready after Ns », aucune valeur de secret |
| 19 | `19-install-phase4.png` | terminal VM | `sudo bash scripts/install-phase4.sh` | images récupérées, 3 lignes « is ready » |
| 20 | `20-compose-ps.png` | terminal VM | `docker compose -f monitoring/docker-compose.yml ps` | 4 services `running` |
| 21 | `21-prometheus-targets.png` | navigateur Windows via tunnel SSH | `http://127.0.0.1:9090/targets` | `devsecops-app`, `node`, `prometheus` **UP** |
| 22 | `22-grafana-dashboard.png` | navigateur Windows | `http://192.168.33.10:3000` → dossier **DevSecOps** | 6 panneaux avec courbes |
| 23 | `23-alerte-firing.png` | navigateur Windows via tunnel | `http://127.0.0.1:9090/alerts` puis Alertmanager `:9093` | `ApplicationDown` **firing** |
| 24 | `24-monitoring-14.png` | terminal VM | `bash scripts/monitoring-check.sh` | `Result: 14 passed, 0 failed` |
| 25 | `25-pipeline-final.png` | Jenkins → vue des stages du build final | build avec `PROD_DEPLOY` + `MONITORING` | 20 stages, verts (SonarQube optionnel) |

## Accès navigateur : Prometheus et Alertmanager ne sont plus publiés

Prometheus (9090), Alertmanager (9093) et node_exporter (9100) sont liés à `127.0.0.1` sur
la VM : ils ne sont **pas** joignables depuis Windows. Ouvrez un tunnel depuis le poste :

```bash
ssh -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 -L 9100:127.0.0.1:9100 vagrant@192.168.33.10
```

Puis, côté Windows, `http://127.0.0.1:9090` (Prometheus) et `http://127.0.0.1:9093`
(Alertmanager). Grafana reste accessible directement : `http://192.168.33.10:3000`.

Mot de passe Grafana (jamais commité) :

```bash
sudo grep GRAFANA_ADMIN_PASSWORD monitoring/.env
```

## Scénario de la capture 23

```bash
docker rm -f devsecops-app
sleep 75
```
Puis rafraîchir `http://127.0.0.1:9090/alerts` : `ApplicationDown` passe de *pending* à
*firing*. Pour la résolution, relancez un build avec `DEPLOY_CONTAINER` coché, ou :

```bash
docker run -d --name devsecops-app --network devsecops-net -p 18080:8080 devsecops-demo:ci
```
