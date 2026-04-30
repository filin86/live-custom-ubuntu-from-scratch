# Инструкция: секреты CI для подписи RAUC и сервера обновлений

Дата: 2026-04-20
Применимость: GitLab CI (`.gitlab-ci.yml`) + промышленная PKI.

## Перечень переменных

| Переменная | Тип GitLab | Protected | Masked | Где используется | Ротация |
|---|---|---|---|---|---|
| `RAUC_SIGNING_CERT` | **File** | yes | — | `rauc bundle --cert` (путь к файлу) | 3-5 лет, по умолчанию 5 лет |
| `RAUC_SIGNING_KEY` | **File** | yes | — | `rauc bundle --key` (путь к файлу) | 3-5 лет, по умолчанию 5 лет |
| `RAUC_INTERMEDIATE_CERT` | **File** (опционально) | yes | — | `rauc bundle --intermediate` | вместе с сертификатом подписи |
| `RAUC_KEYRING` | **File** | yes | — | PEM (`prod-keyring.pem`) → rootfs `/etc/rauc/keyring.pem` и архив установщика | раз в 20 лет (ротация root CA) |
| `UPDATE_SERVER_DEPLOY_TOKEN` | Variable | yes | **yes** | `curl -H "Authorization: Bearer ..."` к `/api/upload` | при компрометации или раз в 6-12 мес |
| `UPDATE_SERVER_URL` | Variable | yes | no | базовый URL для загрузки | при смене инфраструктуры |

**`RAUC_KEYRING` и `RAUC_SIGNING_CERT`**: сертификат подписи используется один
раз — CI подписывает им RAUC-пакет, после чего сертификат физически уходит в
подпись артефакта. Keyring попадает в rootfs и установщик как доверенный
корневой набор: панель без него НЕ доверяет ни одному промышленному
RAUC-пакету, заводская установка с dev-keyring отвергнет prod-подписанный
архив уже на этапе проверки и монтирования RAUC-пакета. Поэтому конвейер
копирует `RAUC_KEYRING` во временный файл и передаёт его как
`RAUC_KEYRING_PATH` и `INSTALLER_KEYRING_SRC`; при промышленной подписи без
keyring сборка прерывается.

Пометка **Protected** означает, что переменная доступна только защищённым
веткам и тегам. Наши выпускные теги `vYYYY.MM.DD.N` обязаны быть защищены в
`Settings → Repository → Protected tags`, иначе конвейер с секретами не
запустится на форк-коммитах или неавторизованных тегах.

Приватный ключ Root CA (`prod-root-ca.key`) **НИКОГДА** не загружается в CI.
Все подписи сертификата подписи делаются вне сети на изолированной машине —
см. `pki/README.md` шаги 1–2.

## GitLab CI

### Шаг 1. Добавить переменные

`Project → Settings → CI/CD → Variables → Add variable`:

1. **`RAUC_SIGNING_CERT`**
   - Type: **File**
   - Value: paste содержимое `prod-signing.crt` (полный PEM с `BEGIN`/`END`)
   - Protect variable: ✓
   - Mask variable: — (File-type нельзя маскировать; runner всё равно не печатает содержимое файла)
2. **`RAUC_SIGNING_KEY`**
   - Type: **File**
   - Value: paste `prod-signing.key`
   - Protect variable: ✓
3. **`RAUC_INTERMEDIATE_CERT`** (опционально, если двухуровневый CA недостаточно)
   - Type: **File**, Protected, содержимое `prod-intermediate.crt`.
4. **`RAUC_KEYRING`**
   - Type: **File**
   - Value: содержимое `prod-keyring.pem` (= `prod-root-ca.crt` в простом двухуровневом CA; concat old+new при переходе на новый root CA).
   - Protect variable: ✓
5. **`UPDATE_SERVER_DEPLOY_TOKEN`**
   - Type: Variable
   - Value: bearer-token (≥32 hex символа)
   - Protect variable: ✓
   - Mask variable: ✓
6. **`UPDATE_SERVER_URL`**
   - Type: Variable, Protected, не masked (URL не секрет).
   - Value: `https://panels.example.com`.

`Settings → Repository → Protected tags`:

- Pattern `v*.*.*.*` → только Maintainers могут push'ить такие теги.
- Pattern `v[0-9]*.[0-9]*.[0-9]*.[0-9]*` точнее; GitLab поддерживает wildcard-паттерны.

### Шаг 2. File-type variables в `.gitlab-ci.yml`

File-type переменные GitLab сам материализует во временные файлы на
runner'е перед стартом job'а. **Имя переменной хранит путь к файлу**, а не
содержимое — именно то, что нужно `rauc bundle --cert="$RAUC_SIGNING_CERT"`.

В нашем `.gitlab-ci.yml` build-bundle job'е:

```yaml
script:
  - |
    if [[ -n "${RAUC_SIGNING_CERT:-}" && -n "${RAUC_SIGNING_KEY:-}" ]]; then
        echo "using prod signing keypair from CI variables"
        # $RAUC_SIGNING_CERT / $RAUC_SIGNING_KEY уже указывают на файлы
    else
        # fallback на dev-keys (только для dev.* версий)
        ...
    fi
  - ./scripts/build-in-docker.sh -
```

`build-in-docker.sh` пробрасывает обе переменные в контейнер через
`-e RAUC_SIGNING_CERT -e RAUC_SIGNING_KEY`, но File-type variable на
хост-runner'е даёт путь, а bind-mount репозитория покрывает не весь
диск — поэтому в shell-executor'е путь `/builds/.../tmp/…` автоматически
виден внутри контейнера через `-v "$CI_PROJECT_DIR:/workspace"`.

**Если signing файлы лежат ВНЕ `$CI_PROJECT_DIR`** (GitLab default:
`/builds/<group>/<project>/.tmp/`), нужно либо:
- скопировать их внутрь `$CI_PROJECT_DIR/.tmp/pki/` перед сборкой,
- либо добавить `-v "<file_dir>:<file_dir>:ro"` в `build-in-docker.sh` env.

См. `.gitlab-ci.yml` — мы делаем первый вариант в fallback-ветке.

### Шаг 3. Маскирование в логах

GitLab CI автоматически маскирует masked variables (тип String, ≥8
символов, без многострочных паттернов). File-type variables в логах
не появляются, потому что фигурирует только путь, не содержимое.

**Чего нельзя:**
- `cat "$RAUC_SIGNING_KEY"` в debug-шаге — PEM попадёт в job log.
- `echo "$UPDATE_SERVER_DEPLOY_TOKEN"` (masking предохранит, но не на 100%
  при base64 encode'е или split'е).
- `set -x` в шаге с `curl -H "Authorization: Bearer $TOKEN"` — trace покажет
  команду с подставленным token'ом (GitLab masking иногда не ловит).

**Что безопасно:**
- `rauc bundle --cert="$RAUC_SIGNING_CERT"` — пишет путь, не содержимое.
- `curl -H "@-" < token_file` — если бы мы клали token в файл.

В `.gitlab-ci.yml` `set -x` не используется; маскирование полагается на
`masked: true` для `UPDATE_SERVER_DEPLOY_TOKEN`.

### Шаг 4. Artifacts

`.gitlab-ci.yml::build-bundle.artifacts.paths` включает только:

- `out/inauto-panel-*.raucb` + `.sha256`
- `out/inauto-panel-installer-*.tar.zst` + `.sha256`

Artifacts НЕ могут содержать temp-каталоги с signing-файлами — GitLab File-type
variables живут в `/builds/.../tmp/…`, что находится за `$CI_PROJECT_DIR` и в
archive не попадает автоматически.

`expire_in: 30 days` — artifact сжатый в zip-архив доступен через UI и API для
download'а / публикации в release asset'ы.

## Ротация

### Signing cert (до истечения production signing cert)

1. На air-gap машине запустить `./pki/generate-prod-signing-cert.sh`.
2. Скопировать `prod-signing.crt` / `prod-signing.key` на флешку.
3. На online-машине (админ): в GitLab `Project → Settings → CI/CD →
   Variables` найти `RAUC_SIGNING_CERT` и `RAUC_SIGNING_KEY` → `Edit` →
   перезагрузить файлы через UI ("Remove" предыдущие File, "Add" новые с
   тем же именем и `Protected/File` флагами).
4. Удалить файлы с флешки и с air-gap (оставив backup root CA).
5. Следующий CI-run подписывает bundle'ы новым signing cert'ом. Панели
   принимают (цепочка → тот же root CA, keyring.pem не меняется).

### `UPDATE_SERVER_DEPLOY_TOKEN`

1. На update server'е:
   ```
   new_token=$(openssl rand -hex 32)
   echo "INAUTO_UPLOAD_TOKEN=$new_token" > /etc/inauto-update/env
   docker compose up -d api
   ```
2. Обновить GitLab CI/CD variable `UPDATE_SERVER_DEPLOY_TOKEN`.
3. Старый token становится невалидным мгновенно.

### Root CA (раз в 20 лет)

См. `pki/README.md` раздел «Ротация root CA». CI-изменения: никакие —
root CA в CI не живёт.

## Что делать при compromise

### Compromise signing key

1. В GitLab `Project → Settings → CI/CD → Variables` удалить `RAUC_SIGNING_KEY`
   (чтобы текущий pipeline немедленно отказался подписывать новым) или
   заменить на invalid placeholder.
2. Сгенерировать новый signing cert от того же root CA.
3. Опционально: включить `check-crl=true` в будущих rootfs-сборках и
   публиковать CRL через update server.
4. Инцидент фиксируется в `pki/STATUS.md`.

### Compromise update server token

1. Ротировать `INAUTO_UPLOAD_TOKEN` на сервере, обновить
   `UPDATE_SERVER_DEPLOY_TOKEN` в GitLab CI/CD Variables.
2. Проанализировать access logs nginx'а / таблицу `bundles` — нет ли
   подозрительных upload'ов между моментом compromise и ротацией.
3. При необходимости — снять скомпрометированные bundle'ы с каналов
   (`UPDATE bundles SET channel='candidate'` → потом delete после аудита).

### Compromise root CA

Катастрофа. Шаги:
1. Немедленно остановить CI (pause workflow).
2. Сгенерировать новый root CA + signing на air-gap.
3. Собрать переходный rootfs с `keyring.pem` = concat(old_root, new_root).
4. Раскатать переходный rootfs как обычный bundle (подписанный **старым**
   signing, панели его примут).
5. После того как все панели на переходной версии — собрать rootfs с
   `keyring.pem` = new_root_only, подписанный **новым** signing.
6. Старый signing cert revoke'нуть в CRL (если включен) или просто
   прекратить использовать.

## Проверочный чек-лист GitLab pipeline'а

- [ ] `RAUC_SIGNING_CERT`/`KEY` помечены Protected **и** File-type в
      CI/CD → Variables.
- [ ] `UPDATE_SERVER_DEPLOY_TOKEN` помечен Protected **и** Masked.
- [ ] Теги `v*.*.*.*` заведены как Protected (`Settings → Repository →
      Protected tags`) — иначе Protected variables недоступны pipeline'у.
- [ ] Job не делает `cat/echo` ключей, `set -x` не включён в шагах со
      signing.
- [ ] `artifacts.paths` включает только `out/*.raucb` и `out/*.tar.zst`.
- [ ] Build финиширует `out/*.raucb` валидно (`rauc info --keyring=pki/dev-keyring.pem`
      в dev, prod-keyring в prod).
- [ ] Upload к update-server'у через `Authorization: Bearer
      $UPDATE_SERVER_DEPLOY_TOKEN`, не hardcoded.
- [ ] В job-logs нет PEM-блоков и token-строк (GitLab Job UI →
      "View raw logs" для финальной проверки).
