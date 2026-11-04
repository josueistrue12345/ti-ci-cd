# Pruebas, Sonar y Dockerfile por stack

Qué poner en `__TEST_COMMAND__`, `__JUNIT_GLOB__`, `__SONAR_PARAMS__` y `__CONTAINER_PORT__` del template.
Ajusta la versión de la imagen a la que use el proyecto (`composer.json`, `.nvmrc`/`engines`, `pom.xml`,
`TargetFramework`, `python_requires`). Todas las pruebas escriben sus reportes en `reports/` o en la ruta
estándar de la herramienta, y Sonar los lee de ahí porque el workspace se ve igual en todos los contenedores.

- [PHP / Laravel](#php--laravel)
- [Node.js](#nodejs)
- [Java / Spring (Maven o Gradle)](#java--spring)
- [.NET](#net) — usa otra forma de correr Sonar
- [Python](#python)

## PHP / Laravel

Las pruebas de `tests/Feature` suelen necesitar BD; corre solo la suite Unit salvo que el proyecto use SQLite en memoria para pruebas (`phpunit.xml` con `DB_CONNECTION=sqlite` y `DB_DATABASE=:memory:`).

```bash
docker run --rm --volumes-from jenkins -w "$WORKSPACE" -u 0 \
  -v __APP__-composer-cache:/tmp/cache \
  composer:2 sh -c "composer install --no-interaction --no-progress --prefer-dist --ignore-platform-reqs \
    && php vendor/bin/phpunit --testsuite Unit --log-junit reports/junit.xml"
```

- JUnit: `reports/junit.xml`
- Sonar: `-Dsonar.sources=app -Dsonar.tests=tests -Dsonar.exclusions=vendor/**,storage/**,bootstrap/cache/**`
- Puerto: el del servidor web de la imagen (80 con nginx/apache; 8000 si usa `php artisan serve`, que no es para producción)
- Dockerfile: etapa `composer:2` para `composer install --no-dev --optimize-autoloader`, y etapa final `php:8.x-fpm` + nginx, o `php:8.x-apache` con `DocumentRoot` en `public/`. Deja la caché de config para el arranque (`php artisan config:cache` necesita las variables de `<app>-env`).

## Node.js

```bash
docker run --rm --volumes-from jenkins -w "$WORKSPACE" -u 0 \
  -v __APP__-npm-cache:/root/.npm \
  -e CI=true -e JEST_JUNIT_OUTPUT_DIR=reports \
  node:22 sh -c "npm ci && npm test -- --coverage"
```

- Usa el gestor que tenga el lockfile: `pnpm-lock.yaml` → `corepack enable && pnpm install --frozen-lockfile`; `yarn.lock` → `corepack enable && yarn install --immutable`.
- JUnit: con Jest, agrega `jest-junit` como reporter (`--reporters=default --reporters=jest-junit`) → `reports/junit.xml`. Con Vitest: `--reporter=junit --outputFile=reports/junit.xml`. Si el proyecto no tiene pruebas, dilo al usuario en vez de inventar un comando que pase en vacío.
- Sonar: `-Dsonar.sources=src -Dsonar.exclusions=**/node_modules/**,**/dist/**,**/*.test.*,**/*.spec.* -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info`
- Puerto: el de la app (suele ser 3000). Un front estático (React/Vue/Angular) se sirve con nginx en 80.
- Dockerfile: etapa `node:22` con `npm ci` + `npm run build`, y etapa final `node:22-slim` con `npm ci --omit=dev` (back) o `nginx:alpine` con el `dist/` (front). Usuario no root (`USER node`).

## Java / Spring

Maven:

```bash
docker run --rm --volumes-from jenkins -w "$WORKSPACE" -u 0 \
  -v __APP__-m2:/root/.m2 \
  maven:3.9-eclipse-temurin-21 mvn -B verify
```

- JUnit: `target/surefire-reports/*.xml`
- Sonar: `-Dsonar.sources=src/main/java -Dsonar.tests=src/test/java -Dsonar.java.binaries=target/classes -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml`. Sonar necesita las clases compiladas, por eso las pruebas van antes. Si el `pom.xml` no tiene el plugin de JaCoCo, quita el parámetro de cobertura o propón agregar el plugin.

Gradle: imagen `gradle:8-jdk21`, comando `gradle test --no-daemon` (o `./gradlew` si existe el wrapper), caché `-v __APP__-gradle:/root/.gradle`.

- JUnit: `build/test-results/test/*.xml`
- Sonar: `-Dsonar.java.binaries=build/classes/java/main -Dsonar.coverage.jacoco.xmlReportPaths=build/reports/jacoco/test/jacocoTestReport.xml`

- Puerto: 8080. Health check: `/actuator/health` si tiene Actuator.
- Dockerfile: etapa `maven:3.9-eclipse-temurin-21` con `mvn -B package -DskipTests`, y etapa final `eclipse-temurin:21-jre` con el `.jar`.

## .NET

El `sonar-scanner-cli` no analiza C#: .NET usa `dotnet-sonarscanner`, que envuelve el build y necesita Java. Por eso **las etapas de Pruebas y Sonar se juntan en una sola**, dentro de `withSonarQubeEnv`. Reemplaza las dos etapas del template por esta:

```groovy
stage('Pruebas + SonarQube') {
  steps {
    withSonarQubeEnv('sonarqube') {
      sh '''
        docker run --rm --volumes-from jenkins --network container:jenkins -w "$WORKSPACE" -u 0 \
          -v __APP__-nuget:/root/.nuget/packages \
          -e SONAR_HOST_URL="$SONAR_HOST_URL" -e SONAR_TOKEN="$SONAR_AUTH_TOKEN" \
          -e APP="$APP" -e WORKSPACE="$WORKSPACE" \
          mcr.microsoft.com/dotnet/sdk:8.0 bash -c '
            set -e
            apt-get update -qq && apt-get install -y -qq openjdk-17-jre-headless > /dev/null
            dotnet tool install --global dotnet-sonarscanner
            export PATH="$PATH:/root/.dotnet/tools"
            dotnet sonarscanner begin /k:"$APP" /n:"$APP" /d:sonar.host.url="$SONAR_HOST_URL" /d:sonar.token="$SONAR_TOKEN" \
              /d:sonar.cs.opencover.reportsPaths="**/coverage.opencover.xml" \
              /d:sonar.qualitygate.wait=true /d:sonar.qualitygate.timeout=300
            dotnet build
            dotnet test --no-build --logger "junit;LogFilePath=$WORKSPACE/reports/{assembly}.xml" \
              --collect "XPlat Code Coverage" -- DataCollectionRunSettings.DataCollector.Configuration.Format=opencover
            dotnet sonarscanner end /d:sonar.token="$SONAR_TOKEN"
          '
      '''
    }
  }
  post {
    always {
      junit allowEmptyResults: true, testResults: 'reports/*.xml'
    }
  }
}
```

- Lo que va dentro de `bash -c '…'` se expande en el contenedor, no en Jenkins: toda variable que use ahí tiene que pasarse con `-e` (por eso `APP`, `WORKSPACE` y las de Sonar).
- El logger `junit` necesita el paquete `JunitXml.TestLogger` en los proyectos de prueba, y la cobertura necesita `coverlet.collector`. Si faltan, dile al usuario que los agregue (`dotnet add <proyecto-de-pruebas> package JunitXml.TestLogger`).
- Usa la versión del SDK que pida el `TargetFramework` (`net8.0` → `sdk:8.0`).
- Puerto: 8080 (default de las imágenes de .NET 8). Health check: el que mapee la app (`app.MapHealthChecks("/health")`).
- Dockerfile: etapa `mcr.microsoft.com/dotnet/sdk:8.0` con `dotnet publish -c Release -o /app`, y etapa final `mcr.microsoft.com/dotnet/aspnet:8.0`.

## Python

```bash
docker run --rm --volumes-from jenkins -w "$WORKSPACE" -u 0 \
  -v __APP__-pip-cache:/root/.cache/pip \
  python:3.12-slim sh -c "pip install -r requirements.txt pytest pytest-cov \
    && pytest --junitxml=reports/junit.xml --cov=. --cov-report=xml:reports/coverage.xml"
```

- Con `pyproject.toml` (Poetry/uv), instala con la herramienta del proyecto (`pip install poetry && poetry install`, `pip install uv && uv sync`) y corre `pytest` con ella.
- JUnit: `reports/junit.xml`
- Sonar: `-Dsonar.sources=. -Dsonar.exclusions=tests/**,**/migrations/** -Dsonar.tests=tests -Dsonar.python.version=3.12 -Dsonar.python.coverage.reportPaths=reports/coverage.xml`
- Puerto: 8000 (Django/FastAPI con gunicorn/uvicorn). Health check: el que exponga la app.
- Dockerfile: `python:3.12-slim`, dependencias primero (aprovecha la caché de capas), luego el código, y un servidor de producción (`gunicorn`, `uvicorn`), no `runserver`/`--reload`.
