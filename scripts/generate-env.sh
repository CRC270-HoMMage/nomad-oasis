#!/bin/bash

# Script to generate a .env file with a random API secret

# Get the directory where the script is located and go to parent directory
PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$PARENT_DIR/.env"

# Check if .env or .env.north file already exists
if [[ -f "$ENV_FILE" || -f "$ENV_FILE.north" ]]; then
  echo "Warning: $ENV_FILE or $ENV_FILE.north already exists."
  read -p "Do you want to overwrite them? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted. Either $ENV_FILE nor $ENV_FILE.north were not modified."
    exit 0
  fi
fi

# Generate a random 64-character API secret using openssl
HUB_SERVICE_API_TOKEN=$(openssl rand -hex 32)

# Generate a random password for the temporal/postgres database. On a fresh deployment
# (empty postgres volume) this becomes the DB password. To rotate it on an ALREADY
# running deployment, changing this value is NOT enough -- see SECURITY-HARDENING.md.
POSTGRES_PASSWORD=$(openssl rand -hex 24)

# Create the .env file and check for errors
if ! cat >"$ENV_FILE" <<EOF; then
NOMAD_SERVICES_API_SECRET='$(openssl rand -hex 32)'

# API token for nomad services to communicate with the hub, can be generated with: openssl rand -hex 32
NOMAD_NORTH_HUB_SERVICE_API_TOKEN='$HUB_SERVICE_API_TOKEN'
POSTGRES_PASSWORD='$POSTGRES_PASSWORD'
# Private-Oasis allowlist. JSON array of CENTRAL NOMAD account e-mails (nomad-lab.eu
# logins) permitted to access this deployment. Overrides auth.authorized_users in
# configs/nomad.yaml. While this stays commented out, the fail-safe floor in
# nomad.yaml applies (access locked to the maintainer). Uncomment and fill before
# onboarding the group:
# NOMAD_AUTH_AUTHORIZED_USERS=["alice@tu-darmstadt.de","bob@tu-darmstadt.de"]
EOF
  echo "Error: Failed to write to $ENV_FILE" >&2
  echo "Please check write permissions for the directory: $PARENT_DIR" >&2
  exit 1
fi

# Create the .env file and check for errors
if ! cat >"$ENV_FILE.north" <<EOF; then
# OAuth2 settings for authentication with Keycloak
#
# NOTE the /auth suffix. Upstream's template writes ".../fairdi/keycloak", which is NOT a
# Keycloak: nomad-lab.eu's front proxy 302s that path to https://nomad-lab.eu/nomad-lab/.
# (It answers identically for a deliberately bogus redirect_uri -- that is how this was
# caught.) The app's own default, nomad.config.keycloak.server_url, is
# ".../fairdi/keycloak/auth", and only that serves the OIDC discovery document.
#
# The hub builds authorize_url as KEYCLOAK_URL + realms/<realm>/protocol/openid-connect/auth,
# so with the short form the browser is bounced to the NOMAD homepage, hub login never
# completes, no auth_state is ever stored, and c.Authenticator.refresh_pre_spawn = True
# rejects EVERY tool launch with:
#     403 ... auth has expired for <user>, login again
# The app is unaffected (it has the right default), so the Oasis logs in fine while NORTH is
# dead -- which is what made this look like a JupyterHub bug rather than a URL typo.
#
# Verified 2026-08-05 against a pristine nomad-distro-template: with the short form a spawn
# 403s, with /auth the notebook starts. Re-check on the next template merge.
#
# Keep this comment free of backticks and dollar-parens -- the heredoc is unquoted, so the
# shell would execute them instead of writing them out.
KEYCLOAK_URL="https://nomad-lab.eu/fairdi/keycloak/auth"
KEYCLOAK_REALM="fairdi_nomad_prod"
OAUTH_CLIENT_ID="nomad_public"
OAUTH_CLIENT_SECRET=""

# API key for nomad services to communicate with the hub, can be generated with: openssl rand -hex 32
SERVICE_API_TOKEN='$HUB_SERVICE_API_TOKEN'

# SAME VALUE, DIFFERENT NAME -- and both are required. jupyterhub_config.py registers the
# privileged 'nomad-service' identity from config.north.hub_service_api_token, which NOMAD
# reads from NOMAD_NORTH_HUB_SERVICE_API_TOKEN, not from SERVICE_API_TOKEN above. That field
# has a default, so omitting this errors nowhere: the hub quietly registers the well-known
# default 'secret-token'. On samarium that left the hub API answerable from the public
# internet with a guessable token -- and nomad-service is the identity pre_spawn trusts to
# launch containers with caller-supplied host mounts, on a host that hands the hub the docker
# socket. After deploying, verify a request with 'Authorization: token secret-token' gets 403.
NOMAD_NORTH_HUB_SERVICE_API_TOKEN='$HUB_SERVICE_API_TOKEN'

# Key for encryption of user_settings, can be generated with: openssl rand -hex 32
JUPYTERHUB_CRYPT_KEY='$(openssl rand -hex 32)'
EOF
  echo "Error: Failed to write to $ENV_FILE.north" >&2
  echo "Please check write permissions for the directory: $PARENT_DIR" >&2
  exit 1
fi

echo "✓ $ENV_FILE and $ENV_FILE.north files are created successfully!"
echo "✓ Generated a 64-character API token and encryption keys."
echo ""
echo "You can now run 'docker compose up -d' to start NOMAD Oasis."
