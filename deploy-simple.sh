#!/bin/bash

# Deploy Simples - Projeto BIA
# Rotina alternativa de deploy com versionamento por commit hash

set -e

# Configurações
REGION="us-east-1"
ECR_REPO="bia"
CLUSTER="cluster-bia"
SERVICE="service-bia"
TASK_FAMILY="task-def-bia"

# Cores
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Obter commit hash
COMMIT_HASH=$(git rev-parse --short=7 HEAD 2>/dev/null || error "Não é um repositório Git")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"

info "=== DEPLOY SIMPLES BIA ==="
info "Commit: $COMMIT_HASH"
info "ECR: $ECR_URI:$COMMIT_HASH"
info "Cluster: $CLUSTER"
info "Service: $SERVICE"

# Verificar se tudo está OK antes de prosseguir
echo
warn "Verificando configurações..."
echo "- Região: $REGION"
echo "- ECR Repo: $ECR_REPO"
echo "- Cluster: $CLUSTER"
echo "- Service: $SERVICE"
echo "- Task Family: $TASK_FAMILY"
echo "- Tag: $COMMIT_HASH"
echo

read -p "Continuar com o deploy? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Deploy cancelado"
    exit 0
fi

# 1. Login ECR
info "1/5 Login ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# 2. Build
info "2/5 Build da imagem..."
docker build -t $ECR_URI:$COMMIT_HASH -t $ECR_URI:latest .

# 3. Push
info "3/5 Push para ECR..."
docker push $ECR_URI:$COMMIT_HASH
docker push $ECR_URI:latest

# 4. Nova Task Definition
info "4/5 Criando task definition..."
TEMP_FILE=$(mktemp)
aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query 'taskDefinition' > $TEMP_FILE
NEW_TASK=$(jq --arg image "$ECR_URI:$COMMIT_HASH" '
    .containerDefinitions[0].image = $image |
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
' $TEMP_FILE)
echo $NEW_TASK > $TEMP_FILE
NEW_REVISION=$(aws ecs register-task-definition --region $REGION --cli-input-json file://$TEMP_FILE --query 'taskDefinition.revision' --output text)
rm -f $TEMP_FILE

# 5. Update Service
info "5/5 Atualizando serviço..."
aws ecs update-service --region $REGION --cluster $CLUSTER --service $SERVICE --task-definition $TASK_FAMILY:$NEW_REVISION > /dev/null

success "Deploy concluído!"
info "Versão: $COMMIT_HASH"
info "Task Definition: $TASK_FAMILY:$NEW_REVISION"
info "Aguardando estabilização..."

aws ecs wait services-stable --region $REGION --cluster $CLUSTER --services $SERVICE
success "Serviço estável!"
