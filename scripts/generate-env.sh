#!/bin/bash

# Script to generate a .env file with a random API secret

# Get the directory where the script is located and go to parent directory
PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$PARENT_DIR/.env"

# Check if .env file already exists
if [ -f "$ENV_FILE" ]; then
    echo "Warning: $ENV_FILE already exists."
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. $ENV_FILE was not modified."
        exit 0
    fi
fi

# Generate a random 64-character API secret using openssl
API_SECRET=$(openssl rand -hex 32)

# Generate a random password for the temporal/postgres database. On a fresh deployment
# (empty postgres volume) this becomes the DB password. To rotate it on an ALREADY
# running deployment, changing this value is NOT enough -- see SECURITY-HARDENING.md.
POSTGRES_PASSWORD=$(openssl rand -hex 24)

# Create the .env file and check for errors
if ! cat > "$ENV_FILE" << EOF
NOMAD_SERVICES_API_SECRET='$API_SECRET'
POSTGRES_PASSWORD='$POSTGRES_PASSWORD'

# Private-Oasis allowlist. JSON array of CENTRAL NOMAD account e-mails (nomad-lab.eu
# logins) permitted to access this deployment. Overrides auth.authorized_users in
# configs/nomad.yaml. While this stays commented out, the fail-safe floor in
# nomad.yaml applies (access locked to the maintainer). Uncomment and fill before
# onboarding the group:
# NOMAD_AUTH_AUTHORIZED_USERS=["alice@tu-darmstadt.de","bob@tu-darmstadt.de"]
EOF
then
    echo "Error: Failed to write to $ENV_FILE" >&2
    echo "Please check write permissions for the directory: $PARENT_DIR" >&2
    exit 1
fi

echo "✓ $ENV_FILE file created successfully!"
echo "✓ Generated a 64-character API secret."
echo "✓ Generated a random POSTGRES_PASSWORD."
echo ""
echo "You can now run 'docker compose up -d' to start NOMAD Oasis."
