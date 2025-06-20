ARG GOLANG_IMAGE_TAG=1.24
FROM --platform=${BUILDPLATFORM} mcr.microsoft.com/oss/go/microsoft/golang:${GOLANG_IMAGE_TAG} AS builder
ARG AVMFIX_VERSION=v0.6.0
ARG GREPT_VERSION=60c71b2d8554c7ec562168a1ffd46a695a73322d
ARG HCLEDIT_VERSION=0.2.17
ARG HCLMERGE_VERSION=2dff14bd831a6f696d6572f03a5a61a11e4e3d66
ARG MAPOTF_VERSION=1a50a9033189df84e72f32c94fe88ab4ff70a0a9
ARG PORCH_VERSION=0.0.10
ARG TERRAFORM_DOCS_VERSION=v0.20.0
ARG TFENV=v3.0.0
ARG GOBUILDARGS='-trimpath'
# The below is set by Buildx for cross-platform builds
ARG TARGETARCH
# Cross compile go binaries
ENV GOARCH=${TARGETARCH}
RUN mkdir /src && \
  cd /src && \
  export CGO_ENABLED=0 && \
  echo "Build conftest" && \
  git clone https://github.com/open-policy-agent/conftest.git && \
  cd conftest && \
  git checkout ${CONFTEST_VERSION} && \
  go get go@1.24.4 && \
  go mod tidy && \
  go build ${GOBUILDARGS} -o /go/bin/conftest . && \
  cd /src && \
  echo "Build hcledit" && \
  git clone https://github.com/minamijoyo/hcledit.git && \
  cd hcledit && \
  git checkout v${HCLEDIT_VERSION} && \
  go get go@1.24.4 && \
  go get gopkg.in/yaml.v2@v2.2.8 && \
  go mod tidy && \
  go build ${GOBUILDARGS} -o /go/bin/hcledit . && \
  cd /src && \
  echo "Build hclgrep" && \
  git clone https://github.com/magodo/hclgrep && \
  cd hclgrep && \
  git checkout main && \
  go build ${GOBUILDARGS} -o /go/bin/hclgrep . && \
  cd /src && \
  echo "Build avmfix" && \
  git clone https://github.com/lonegunmanb/avmfix && \
  cd avmfix && \
  git checkout ${AVMFIX_VERSION} && \
  go build ${GOBUILDARGS} -o /go/bin/avmfix . && \
  cd /src && \
  echo "Build grept" && \
  git clone https://github.com/Azure/grept && \
  cd grept && \
  git checkout ${GREPT_VERSION} && \
  go build ${GOBUILDARGS} -o /go/bin/grept . && \
  cd /src && \
  echo "Build hclmerge" && \
  git clone https://github.com/lonegunmanb/hclmerge && \
  cd hclmerge && \
  git checkout ${HCLMERGE_VERSION} && \
  go build ${GOBUILDARGS} -o /go/bin/hclmerge . && \
  echo "Build terraform-docs" && \
  git clone https://github.com/terraform-docs/terraform-docs.git && \
  cd terraform-docs && \
  git checkout ${TERRAFORM_DOCS_VERSION} && \
  go get go@1.24.4 && \
  go get golang.org/x/net@v0.38.0 && \
  go mod tidy && \
  go build ${GOBUILDARGS} -o /go/bin/terraform-docs . && \
  echo "Build mapotf" && \
  git clone https://github.com/Azure/mapotf && \
  cd mapotf && \
  git checkout ${MAPOTF_VERSION} && \
  go build ${GOBUILDARGS} -o /go/bin/mapotf . && \
  cd /src && \
  echo "Build porch" && \
  curl -sL https://github.com/matt-FFFFFF/porch/releases/download/v${PORCH_VERSION}/porch_${PORCH_VERSION}_linux_${TARGETARCH}.tar.gz -o porch.tar.gz && \
  tar -xzf porch.tar.gz && \
  mv porch /go/bin && \
  echo "Build tflintenv" && \
  git clone https://github.com/lonegunmanb/tflintenv.git && \
  cd tflintenv && cd tflintenv && go build ${GOBUILDARGS} -o /go/bin/tflintenv && \
  cd ../tflint && go build ${GOBUILDARGS} -o /go/bin/tflint && \
  cd /src && \
  echo "Build terrafmt" && \
  git clone https://github.com/lonegunmanb/terrafmt.git && \
  cd terrafmt && \
  go build ${GOBUILDARGS} -o /go/bin/terrafmt . && \
  cd /src && \
  echo "Fetch tfenv" && \
  git clone https://github.com/tfutils/tfenv.git && \
  cd /src/tfenv && \
  git checkout $TFENV && \
  rm -rf .git && \
  cd /src && \
  rm -rf .git && \
  chmod a+x /go/bin/*

FROM mcr.microsoft.com/azurelinux/base/core:3.0
ARG CONFTEST_VERSION=0.60.0
ARG HOME_DIR=/home/runtimeuser
ARG TERRAFORM_VERSION=1.12.1
ARG TFLINT_VERSION=v0.58.0
ENV AVM_IN_CONTAINER=1
ENV AVM_MOD_PATH=/src
ENV PATH=$PATH:${HOME_DIR}/tfenv/bin
ENV TF_CLI_CONFIG_FILE=${HOME_DIR}/.terraformrc
ENV TFENV_AUTO_INSTALL=true
ENV TFENV_TERRAFORM_VERSION=${TERRAFORM_VERSION}
ENV TFLINT_PLUGIN_DIR=${HOME_DIR}/tflint
ENV TFLINTENV_DEFAULT_VERSION=${TFLINT_VERSION}
ENV TFLINTENV_HOME_DIR=${HOME_DIR}/tflintenv
COPY --from=builder /go/bin /usr/local/bin
COPY --from=builder /src/tfenv ${HOME_DIR}/tfenv
# The below is set by Buildx for cross-platform builds
ARG TARGETARCH
RUN tdnf install -y ca-certificates azure-cli gawk git jq less make powershell unzip wget zip && \
  tdnf upgrade --security -y && \
  tdnf clean all && \
  git config --global user.email "tfmod442916@users.noreply.github.com" && \
  git config --global user.name "github-actions[bot]" && \
  git config --global --add safe.directory '*' && \
  mkdir -p ${HOME_DIR} && \
  cp /root/.gitconfig ${HOME_DIR}/.gitconfig && \
  mkdir ${HOME_DIR}/tflintenv && \
  chmod -R a+rwX ${HOME_DIR} && \
  chmod a+x ${HOME_DIR}/tfenv/bin/* && \
  rm -r /tmp/* && \
  cd /root && \
  mkdir /src && \
  chmod a+rwX /src
COPY .terraformrc ${HOME_DIR}/.terraformrc
ENV HOME=${HOME_DIR}
ENV SHELL=/bin/bash
WORKDIR /src
