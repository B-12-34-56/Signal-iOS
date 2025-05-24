#!/bin/bash

# AWS Configuration Setup Script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate AWS credentials
validate_aws_credentials() {
    echo -e "${YELLOW}Validating AWS credentials...${NC}"
    
    if ! command_exists aws; then
        echo -e "${RED}AWS CLI is not installed. Please install it first.${NC}"
        exit 1
    }
    
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo -e "${RED}AWS credentials are not valid. Please configure your AWS credentials.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}AWS credentials are valid.${NC}"
}

# Function to validate environment variables
validate_env_vars() {
    local required_vars=(
        "AWS_ACCESS_KEY_ID"
        "AWS_SECRET_ACCESS_KEY"
        "AWS_REGION"
        "S3_BUCKET_NAME"
        "DYNAMODB_TABLE_NAME"
        "COGNITO_IDENTITY_POOL_ID"
        "GET_TAG_API_KEY"
        "UPLOAD_IMAGE_API_KEY"
        "GET_TAG_API_GATEWAY_ARN"
        "UPLOAD_IMAGE_API_GATEWAY_ARN"
    )
    
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo -e "${RED}Missing required environment variables:${NC}"
        printf '%s\n' "${missing_vars[@]}"
        exit 1
    fi
    
    echo -e "${GREEN}All required environment variables are set.${NC}"
}

# Function to create AWS resources if they don't exist
create_aws_resources() {
    echo -e "${YELLOW}Checking AWS resources...${NC}"
    
    # Check S3 bucket
    if ! aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null; then
        echo -e "${YELLOW}Creating S3 bucket: $S3_BUCKET_NAME${NC}"
        aws s3api create-bucket \
            --bucket "$S3_BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    
    # Check DynamoDB table
    if ! aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" 2>/dev/null; then
        echo -e "${YELLOW}Creating DynamoDB table: $DYNAMODB_TABLE_NAME${NC}"
        aws dynamodb create-table \
            --table-name "$DYNAMODB_TABLE_NAME" \
            --attribute-definitions AttributeName=imageHash,AttributeType=S \
            --key-schema AttributeName=imageHash,KeyType=HASH \
            --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
            --region "$AWS_REGION"
    fi
    
    echo -e "${GREEN}AWS resources are ready.${NC}"
}

# Function to generate environment file
generate_env_file() {
    echo -e "${YELLOW}Generating environment file...${NC}"
    
    cat > .env << EOF
# AWS Configuration
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
AWS_REGION=$AWS_REGION

# S3 Configuration
S3_BUCKET_NAME=$S3_BUCKET_NAME
S3_REGION=$AWS_REGION
S3_IMAGES_PATH=images
S3_BASE_URL=https://$S3_BUCKET_NAME.s3.$AWS_REGION.amazonaws.com

# DynamoDB Configuration
DYNAMODB_TABLE_NAME=$DYNAMODB_TABLE_NAME
DYNAMODB_REGION=$AWS_REGION
DYNAMODB_ENDPOINT=https://dynamodb.$AWS_REGION.amazonaws.com

# API Gateway Configuration
API_GATEWAY_ENDPOINT=https://api.signal.org
GET_TAG_API_KEY=$GET_TAG_API_KEY
UPLOAD_IMAGE_API_KEY=$UPLOAD_IMAGE_API_KEY
GET_TAG_API_GATEWAY_ARN=$GET_TAG_API_GATEWAY_ARN
UPLOAD_IMAGE_API_GATEWAY_ARN=$UPLOAD_IMAGE_API_GATEWAY_ARN

# Cognito Configuration
COGNITO_IDENTITY_POOL_ID=$COGNITO_IDENTITY_POOL_ID
COGNITO_REGION=$AWS_REGION

# Timeouts and Retries
REQUEST_TIMEOUT=30
RESOURCE_TIMEOUT=300
MAX_RETRY_COUNT=3
INITIAL_RETRY_DELAY=1
MAX_RETRY_DELAY=10
DEFAULT_TTL_DAYS=30
EOF
    
    echo -e "${GREEN}Environment file generated successfully.${NC}"
}

# Main script execution
echo -e "${YELLOW}Starting AWS environment setup...${NC}"

# Validate AWS credentials
validate_aws_credentials

# Validate environment variables
validate_env_vars

# Create AWS resources
create_aws_resources

# Generate environment file
generate_env_file

echo -e "${GREEN}AWS environment setup completed successfully!${NC}"
echo -e "${YELLOW}Please source the .env file to use the environment variables:${NC}"
echo -e "source .env" 