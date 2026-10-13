# Plan: Strata auf Runpod

Stand: eine Variante. Der Strata-Ordner und die Modelldaten laufen unter `/tmp` (lokale Platte), das Netzwerk-Volume ist nur die Ablage.
Details: `README.md`. Gemessen auf den Pods: Network Volume `geesefs` 8 MiB/s und MooseFS 15 MiB/s bei 4-KiB-Zufallslesen, deshalb lokal.

## Entscheidungen
- Ein Image (`strata-runpod`); die Engine wird auf dem Pod gebaut (3-4 min), als Archiv `app-<key>.tar` im Store abgelegt und bei
  gleichem Schluessel (GPU-Architektur, CPU-Flags, Strata-Commit) wiederhergestellt (ca. 0,5 GB).
- `COPY_DATA_LOCAL=yes` (Standard): Daten werden vom Store nach `/tmp/Strata-data` kopiert, `no`: bleiben auf dem Volume.
- Modell: `--family qwen --model IQ2_XS` (Strata-Empfehlung); `LOW_RAM=resident` bei begrenztem Pod-RAM; `STRATA_API_KEY` Pflicht (Alias `API_KEY`).
- Pod-RAM und -CPU liest Strata falsch (Host-Werte): `POOL_WORKERS` aus `cpu.max`, `LOW_RAM` explizit.

## Naechste Schritte
1. Image bauen (`dev.yml`), Pod mit 200 GB Container-Disk und Volume starten, `start.sh` per Hand in tmux ausfuehren.
2. Erster Lauf: Setup in `/tmp`, danach pruefen, dass `publish.log` im Store Archiv und Daten meldet.
3. Zweiter Pod/Neustart: Wiederherstellung aus dem Store messen (Archiv, Datenkopie, Startzeit).
4. Kalibrierung (`/app/scripts/calibrate.sh`) einmal pro Pod-Typ; Benchmark (`bench-local.sh`); Vergleich vLLM.
5. Serverless (Load-Balancing-Endpoint in der Konsole, Network Volume im selben Rechenzentrum, `MODE=lb`); Kaltstart messen.

## Offen
- Echtes Zusammenspiel mit Strata (Hook in `docker-entrypoint.sh`, Pfade in der Konfiguration).
- Welche Dateien zur Laufzeit zufaellig gelesen werden (`/proc/<pid>/maps`), ob `models/` lokal sein muss.
- Ob `setup.py` ein fertiges Linux-Engine-Asset findet (hier kompiliert es).
