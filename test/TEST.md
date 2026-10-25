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

## 11. `_run`: comando eseguito al cambio di branch

A differenza dello scenario `pass`, questo è già abilitato di default nella
fixture (non richiede setup esterno): il branch `run-demo` scrive una riga
in un file di log (per una verifica deterministica) *e* stampa una riga sul
proprio stdout (per verificare che tu la veda davvero a terminale).

Nota: come per ogni altro scenario in questa guida, `_run` viene valutato
solo quando mise ricalcola l'ambiente (`mise env`, o il prompt della shell
con l'integrazione attiva) — un semplice `git checkout` da solo, senza una
chiamata successiva a `mise env`, non attiva nulla.

```bash
cd demo
rm -f run-demo.log
git checkout run-demo    # primo ingresso sul branch
mise env >/dev/null      # -> deve eseguire
cat run-demo.log
```
Atteso: una riga `RAN branch=run-demo app=run-demo` nel file, e sul
terminale - nonostante il comando sopra reindirizzi *stdout* a
`/dev/null` - la riga `_run says: now on run-demo (this line is on
stderr, not captured by mise)`. Se la vedi comunque è la prova che
l'output di `_run` arriva su stderr, non su stdout.

```bash
git checkout main && mise env >/dev/null   # per riportare lo stato a "visto" su main
git checkout run-demo
mise env 1>/dev/null 2>&1 | grep "_run says"
```
Qui invece reindirizziamo anche stderr nella pipe (`2>&1` dopo
`1>/dev/null`, nell'ordine giusto) e lo filtriamo con `grep`: deve
comunque comparire. Il punto è che l'output di `_run` non deve **mai**
finire nello stesso stdout che una shell con `mise activate` manda a
`eval` ad ogni prompt - altrimenti romperebbe il prompt successivo con un
"command not found" (verificato mentre si progettava questa feature,
vedi README.md).

```bash
mise env >/dev/null      # stesso branch, nessun nuovo switch -> NON deve rieseguire
cat run-demo.log
```
Atteso: ancora una sola riga.

```bash
git checkout main        # switch via (main non definisce _run)
mise env >/dev/null
git checkout run-demo    # e ritorno -> un nuovo vero cambio di branch, deve rieseguire
mise env >/dev/null
cat run-demo.log
```
Atteso: una seconda riga `RAN branch=run-demo app=run-demo`. Il passaggio
per `main` (che non ha `_run`) non deve "nascondere" il cambiamento: il
marker di stato traccia l'ultimo branch visto indipendentemente dal fatto
che quel branch definisca `_run` o no — altrimenti un giro A → B (senza
`_run`) → A verrebbe letto come "nessun cambiamento" al ritorno su A.

```bash
mise env | grep -i "_run" || echo "corretto: _run non è mai esportata come env var"
```

Verifica anche i permessi del marker di stato (stessa logica 700/600 della
cache `pass`, qui senza TTL):
```bash
stat -c '%a' "${TMPDIR:-/tmp}/mise-git-branch-env-run-state"      # atteso: 700
stat -c '%a' "${TMPDIR:-/tmp}/mise-git-branch-env-run-state"/*    # atteso: 600
```

Per testare il caso di fallimento/timeout senza modificare la fixture,
puoi temporaneamente cambiare `_run` in `demo/.mise.toml` sul branch
`run-demo` in `_run = "exit 1"` oppure `_run = "sleep 20"` (timeout a 15s):
in entrambi i casi `mise env` deve comunque restituire le altre variabili
correttamente, e una seconda chiamata subito dopo (stesso branch) deve
essere istantanea — il comando rotto non viene ritentato ad ogni prompt.

**Attenzione:** `_run` esegue comandi arbitrari ogni volta che entri in un
repo con un branch per cui è definito. Va bene per questa fixture (file
temporaneo, nessun side-effect reale), ma non va mai messo in un
`.mise.toml` condiviso senza fidarti di chiunque possa pusciare su quel
repo — vedi README.md per il threat model completo.

## Pulizia della fixture

```bash
test/cleanup.sh <output-dir-che-setup.sh-ha-stampato>
```
Rimuove il worktree correttamente e poi l'intera directory. Non tocca il
plugin linkato né il tuo password store.
