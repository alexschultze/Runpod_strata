> **Branch `strata-v2-dev` (Strata 0.2):** Stand und Unterschiede siehe README.md / README_DETAILS.md; dieses Dokument beschreibt überwiegend die 0.1-Linie.

# Aufgabenteilung: Cloud-Sitzung <-> lokaler Claude (SSH)

Die Cloud-Sitzung hat nur HTTPS ueber einen Proxy (kein SSH, kein rohes TCP) und kann nicht auf den Pod.
Der lokale Claude hat SSH zum Pod und debuggt dort.

| | Cloud-Sitzung | Lokal (SSH) |
|---|---|---|
| Aufgabe | Dockerfiles, `start.sh`, Strata-Image, Workflows, Doku | Pod pruefen, Fehler reproduzieren, Logs sammeln |
| Ergebnis | Commit + Push auf `claude/strata-runpod-deploy-zegtn6`, Build per GitHub Actions | `docs/debug-log.md` (kurze Befunde mit Befehl + Ausgabe), Commit + Push auf denselben Branch |

Regeln: kleine Commits, vor jedem Push `git pull --rebase`. Keine Secrets, Keys oder Tokens ins Repo oder in Logs
(`PUBLIC_KEY`, `HF_TOKEN`, `RUNPOD_API_KEY` ausschwaerzen).

## Stand

- Ein Image: `ghcr.io/alexschultze/strata-runpod:v0.1.<run>` (Workflow `dev.yml`, nur auf Anweisung des Nutzers gestartet). Engine und Daten laufen unter `/tmp`,
  das Volume ist die Ablage (`<volume>/strata-store`). Start per Hand: `STRATA_API_KEY=... /opt/runpod/start.sh` in tmux (`AUTO_START=yes` startet automatisch).
- Vom Nutzer auf echten Pods geprueft: Start mit Engine-Archiv und Datenkopie (ca. 3,5 min), Kalibrierung auf einer RTX PRO 4500 Blackwell, Queue-Worker und Proxy-URL.
  Noch offen: Neu-Setup bei Hardware-Wechsel, `STRATA_PARALLEL`-Gewinn, Load-Balancer-Modus, `/api_direct`.

## Pruefliste fuer den lokalen Claude (im Pod)

```
/app/scripts/check-env.sh                    # Treiber >= 580, CUDA >= 13.0, RAM, Pfade
cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max
env | grep -E '^(MODE|MODEL|FAMILY|CONTEXT|LOW_RAM|COPY_DATA_LOCAL|POOL_WORKERS|STRATA_)'
/app/scripts/test-local-storage.sh 4 15      # /tmp/strata-bench und /dev/shm
/app/scripts/test-network-storage.sh 4 15    # /workspace, /data, /runpod-volume (falls vorhanden)
GIT=1 /app/scripts/test-smallfiles.sh        # Kleindateien: /workspace gegen /tmp
/app/scripts/test-download.sh                # Internet -> Pod
/app/scripts/bench-local.sh --n 3            # wartet auf /health, dann TTFT/tok/s
tail /workspace/strata-store/logs/publish.log
```

Ergebnis je Skript in `docs/debug-log.md`: Ausgabe 1:1 (ohne Keys/Tokens), dazu Pod-Typ, GPU, Region, Volume-Typ. Abweichungen betreffen
die Cloud-Sitzung (Dockerfile, `start.sh`, `scripts/`), bitte konkret benennen (Datei, Zeile, erwartetes Verhalten).

## Naechste Schritte (Cloud)

1. Befunde aus `docs/debug-log.md` in `Dockerfile`/`start.sh` einarbeiten; ein Build nur auf Anweisung des Nutzers.
2. Offene Punkte oben auf echter Hardware bestaetigen (Hardware-Wechsel, `STRATA_PARALLEL`, Load Balancer).
