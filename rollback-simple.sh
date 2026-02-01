#!/bin/bash

# Rollback Simples - Projeto BIA
# Rollback para versão específica

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

# Verificar parâmetro
if [ -z "$1" ]; then
    error "Usage: $0 <commit-hash>"
fi

TARGET_TAG="$1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"

info "=== ROLLBACK SIMPLES BIA ==="
info "Target: $TARGET_TAG"
info "ECR: $ECR_URI:$TARGET_TAG"

# Verificar se a imagem existe
info "Verificando se a imagem existe..."
if ! aws ecr describe-images --repository-name $ECR_REPO --region $REGION --image-ids imageTag=$TARGET_TAG > /dev/null 2>&1; then
    error "Imagem $TARGET_TAG não encontrada no ECR"
fi

warn "Fazendo rollback para: $TARGET_TAG"
read -p "Continuar? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Rollback cancelado"
    exit 0
fi

# Criar nova task definition
info "Criando task definition para rollback..."
CURRENT_TASK=$(aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query 'taskDefinition')
NEW_TASK=$(echo $CURRENT_TASK | jq --arg image "$ECR_URI:$TARGET_TAG" '
    .containerDefinitions[0].image = $image |
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
')
NEW_REVISION=$(echo $NEW_TASK | aws ecs register-task-definition --region $REGION --cli-input-json file:///dev/stdin --query 'taskDefinition.revision' --output text)

# Update Service
info "Atualizando serviço..."
aws ecs update-service --region $REGION --cluster $CLUSTER --service $SERVICE --task-definition $TASK_FAMILY:$NEW_REVISION > /dev/null

success "Rollback concluído!"
info "Versão atual: $TARGET_TAG"
info "Task Definition: $TASK_FAMILY:$NEW_REVISION"

aws ecs wait services-stable --region $REGION --cluster $CLUSTER --services $SERVICE
success "Serviço estável!"
