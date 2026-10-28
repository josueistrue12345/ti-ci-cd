# Jenkins con lo necesario para el pipeline de mobofacil:
# Docker CLI, kubectl y kind, plugins y configuración como código (casc.yaml).
FROM jenkins/jenkins:lts-jdk21

USER root

COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker
# Misma versión de Kubernetes y de kind que el cluster local
RUN curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl \
 && curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64 \
 && chmod +x /usr/local/bin/kubectl /usr/local/bin/kind \
 && git config --system --add safe.directory '*'

# Mirror fijo: desde la red de la oficina varios mirrors de Jenkins no conectan.
# Otros que funcionan: https://ftp-nyc.osuosl.org/pub/jenkins  https://mirror.xmission.com/jenkins
ARG JENKINS_UC_DOWNLOAD=https://ftp-chi.osuosl.org/pub/jenkins
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN JENKINS_UC_DOWNLOAD=$JENKINS_UC_DOWNLOAD jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY casc.yaml /usr/share/jenkins/ref/casc.yaml

USER jenkins
