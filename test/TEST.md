# git-branch-env — guida ai test

Dopo aver lanciato `test/setup.sh [output-dir]` dalla root del plugin, avrai
una fixture pronta all'uso (repo demo, worktree, directory fuori da git,
tutte con `.mise.toml` già `trust`-ato e il plugin già linkato). Questo file
viene copiato automaticamente dentro il repo demo come `TEST.md`.

Ogni blocco sotto mostra cosa aspettarti: se un comando ti dà qualcosa di
diverso, è una regressione da investigare.

## 1. Default + branch esatto (priorità più alta)

```bash
cd demo
git checkout main
mise env | grep -E 'APP_ENV|LOG_LEVEL|DATABASE_URL|GIT_BRANCH'
```
Atteso: `APP_ENV=production`, `LOG_LEVEL=warn`, `DATABASE_URL=postgresql://localhost/prod`,
`GIT_BRANCH=main`, `GIT_BRANCH_SAFE=MAIN`.

```bash
git checkout develop   # poi staging
mise env | grep -E 'APP_ENV|LOG_LEVEL|DATABASE_URL'
```
`develop` → `development`/`debug`/`.../dev`. `staging` → `staging`/`info`/`.../staging`.

## 2. Pattern (prefix) + default non sovrascritto

```bash
git checkout bugfix/login-fix
mise env | grep -E 'APP_ENV|LOG_LEVEL|PATTERN_SOURCE'
```
Atteso: `APP_ENV=bugfix`, `LOG_LEVEL=debug`, `PATTERN_SOURCE=bugfix-prefix`.

```bash
git checkout hotfix/urgent-payment
mise env | grep -E 'APP_ENV|LOG_LEVEL|PATTERN_SOURCE'
```
Atteso: `APP_ENV=hotfix`, `LOG_LEVEL=warn`, `PATTERN_SOURCE=hotfix-prefix`.

```bash
git checkout chore/cleanup-temp   # non matcha nessun pattern/branch
mise env | grep -E 'APP_ENV|LOG_LEVEL|PATTERN_SOURCE|GIT_BRANCH'
```
Atteso: solo i valori di `default` (`development`/`info`/`none`), ma `GIT_BRANCH`
comunque esportato — sei in un repo git, semplicemente nessuna regola branch-specifica
matcha.

## 3. Priorità tra pattern: "più lungo vince"

`feature/new-ui-v2` matcha sia il pattern prefix `"feature/"` (8 caratteri)
sia il pattern glob `"feat*"` (5 caratteri) — per la regola documentata deve
vincere quello più lungo/specifico.

```bash
git checkout feature/new-ui-v2
mise env | grep -E 'APP_ENV|LOG_LEVEL|PATTERN_SOURCE|GIT_BRANCH_SAFE'
```
Atteso: `APP_ENV=feature`, `LOG_LEVEL=debug`, `PATTERN_SOURCE=feature-prefix`
(non `feat-glob`), `GIT_BRANCH_SAFE=FEATURE_NEW_UI_V2` (verifica anche la
sanitizzazione: `/` e `-` diventano `_`, tutto maiuscolo).

```bash
git checkout feat-quick   # matcha SOLO il glob "feat*", non il prefix "feature/"
mise env | grep -E 'APP_ENV|LOG_LEVEL|PATTERN_SOURCE'
```
Atteso: `APP_ENV`/`LOG_LEVEL` restano ai valori di `default` (il pattern glob
imposta solo `PATTERN_SOURCE`), `PATTERN_SOURCE=feat-glob`.

## 4. Branch esatto che sovrascrive un pattern (solo su quel branch)

```bash
git checkout feature/experimental
mise env | grep -E 'APP_ENV|LOG_LEVEL|FEATURE_FLAG|PATTERN_SOURCE'
```
Atteso: `APP_ENV=trace-feature`, `LOG_LEVEL=trace` (dal blocco `branches`,
priorità massima), ma `FEATURE_FLAG=true` e `PATTERN_SOURCE=feature-prefix`
**restano** (vengono dal pattern `"feature/"` e non sono ridefiniti nel
blocco branch esatto).

## 5. HEAD distaccato (detached)

```bash
git checkout "$(git rev-parse main)"
mise env | grep GIT_BRANCH
git checkout main
```
Atteso: `GIT_BRANCH=HEAD`, `GIT_BRANCH_SAFE=HEAD`.

## 6. Worktree (risoluzione del vero HEAD per-worktree)

```bash
cd ../demo-worktree
mise env | grep -E 'GIT_BRANCH|APP_ENV|LOG_LEVEL'
```
Atteso: `GIT_BRANCH=worktree-demo` — **indipendente** dal branch checkout-ato
nel repo principale. Se torni in `demo` e lanci `mise env`, deve ancora
mostrare il branch di lì, non quello del worktree. Verifica che il plugin
risolva il file `HEAD` giusto per worktree (`.git/worktrees/<nome>/HEAD`),
non un `.git/HEAD` fisso.

## 7. Fuori da un repo git

```bash
cd ../demo-outside-git
mise env
```
Atteso: solo `APP_ENV=development`, `LOG_LEVEL=info`, `PATTERN_SOURCE=none`
(il blocco `default`). **Nessun** `GIT_BRANCH`/`GIT_BRANCH_SAFE`.

## 8. Zero fork di `git` (sanity check delle performance)

```bash
cd ../demo
env PATH=/nonexistent "$(command -v mise || echo /usr/local/bin/mise)" env | grep GIT_BRANCH
```
Se il tuo `mise` è una funzione di shell (es. su zsh) e questo comando dice
"No such file or directory", usa il path assoluto del binario reale, es.
`env PATH=/nonexistent /usr/local/bin/mise env`. Atteso: `GIT_BRANCH=main`
comunque presente — la rilevazione del branch non ha bisogno che `git` sia
nel `PATH` del processo.

## 9. Verifica del caching/hook (debug)

```bash
MISE_DEBUG=1 mise env 2>&1 | grep -i git-branch-env
```
Vedrai una riga `[vfox:git-branch-env] mise_env` — l'hook Lua che gira. Su
alcune build di `mise` questa riga appare ad ogni chiamata anche a branch
invariato: il `watch_files`/`cacheable` dichiarato dal plugin non garantisce
uno skip osservabile su ogni versione, ma resta corretto e forward-compatible
(vedi README.md del plugin).

## 10. (Opzionale) Secret via `pass`

Non toccato dal setup automatico: `test/setup.sh` non crea né legge nulla nel
tuo password store reale. Per provarlo:

1. Crea una entry di prova: `pass insert test/git-branch-env-demo/secret`.
2. In `demo/.mise.toml`, decommenta e adatta:
   ```toml
   [env._.git-branch-env.branches.secrets-demo]
   DEMO_SECRET = { pass = "test/git-branch-env-demo/secret" }
   ```
3. `mise trust && git checkout secrets-demo && mise env | grep DEMO_SECRET`
4. Verifica la cache TTL (5s): confronta il tempo di due `mise env` consecutive
   entro 5s (la seconda deve essere più rapida), poi una terza dopo 6s di
   pausa (deve tornare lenta e riscrivere la cache).
5. Verifica i permessi hardened sulla cache:
   ```bash
   stat -c '%a' "${TMPDIR:-/tmp}/mise-git-branch-env-pass-cache"      # atteso: 700
   stat -c '%a' "${TMPDIR:-/tmp}/mise-git-branch-env-pass-cache"/*    # atteso: 600
   ```
6. Pulizia: `pass rm test/git-branch-env-demo/secret` e ricommenta il blocco
   nel `.mise.toml` (o semplicemente non riusare questa fixture).

## Pulizia della fixture

```bash
test/cleanup.sh <output-dir-che-setup.sh-ha-stampato>
```
Rimuove il worktree correttamente e poi l'intera directory. Non tocca il
plugin linkato né il tuo password store.
