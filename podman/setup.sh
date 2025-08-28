#!/bin/sh
set -e

# Documenso Podman Setup Script
# This script sets up Documenso using Quadlets for systemd integration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCUMENSO_DIR="${SCRIPT_DIR}"

printf "=== Setting up Documenso with Podman ===\n"

# Volume directories in /srv/documenso (should be created by services.sh with proper permissions)
DOCUMENSO_VOLUMES="/srv/documenso"
printf "Using volume directory: %s\n" "$DOCUMENSO_VOLUMES"

# Verify volume directories exist and are accessible
if [ ! -d "$DOCUMENSO_VOLUMES" ]; then
    printf "Error: Volume directory %s does not exist or is not accessible\n" "$DOCUMENSO_VOLUMES" >&2
    printf "This should be created by services.sh with proper permissions\n" >&2
    exit 1
fi

# Pre-create certificate file (self-signed for testing)
printf "Creating default signing certificate...\n"
if [ ! -f "${DOCUMENSO_VOLUMES}/cert.p12" ]; then
    # Create a basic self-signed certificate for testing
    # Note: In production, you should replace this with a proper certificate
    openssl req -x509 -newkey rsa:2048 -keyout "${DOCUMENSO_VOLUMES}/temp.key" -out "${DOCUMENSO_VOLUMES}/temp.crt" \
        -days 365 -nodes -subj "/CN=documenso.local/O=Documenso/C=US" 2>/dev/null || {
        printf "Warning: Could not create self-signed certificate. OpenSSL may not be available.\n"
        printf "You will need to provide a valid certificate at ${DOCUMENSO_VOLUMES}/cert.p12\n"
    }
    
    if [ -f "${DOCUMENSO_VOLUMES}/temp.key" ] && [ -f "${DOCUMENSO_VOLUMES}/temp.crt" ]; then
        openssl pkcs12 -export -out "${DOCUMENSO_VOLUMES}/cert.p12" \
            -inkey "${DOCUMENSO_VOLUMES}/temp.key" -in "${DOCUMENSO_VOLUMES}/temp.crt" \
            -passout pass:documenso 2>/dev/null || {
            printf "Warning: Could not create PKCS12 certificate.\n"
        }
        rm -f "${DOCUMENSO_VOLUMES}/temp.key" "${DOCUMENSO_VOLUMES}/temp.crt"
        printf "Created self-signed certificate for testing (password: documenso)\n"
    fi
fi

chmod 644 "${DOCUMENSO_VOLUMES}/cert.p12" 2>/dev/null || true

# Check Podman version for .pod Quadlet support
PODMAN_VERSION=$(podman --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
PODMAN_MAJOR=$(echo "$PODMAN_VERSION" | cut -d. -f1)

if [ "$PODMAN_MAJOR" -lt 5 ]; then
    printf "Podman %s detected - .pod Quadlets not supported, creating pod manually...\n" "$PODMAN_VERSION"
    
    # Parse pod file to extract configuration
    POD_FILE="${DOCUMENSO_DIR}/documenso.pod"
    if [ -f "$POD_FILE" ]; then
        # Extract publish ports from pod file
        PUBLISH_PORTS=$(grep "^PublishPort=" "$POD_FILE" | sed 's/PublishPort=/--publish /' | tr '\n' ' ')
        
        # Remove existing pod and its containers if it exists
        if podman pod exists documenso-pod; then
            printf "Cleaning up existing pod 'documenso-pod'...\n"
            # Force stop and remove all containers in the pod first
            podman pod stop documenso-pod 2>/dev/null || true
            podman ps -a --pod --filter pod=documenso-pod --format "{{.ID}}" | xargs -r podman rm -f 2>/dev/null || true
            # Now remove the pod
            podman pod rm -f documenso-pod 2>/dev/null || true
            # Verify pod is gone
            if podman pod exists documenso-pod; then
                printf "Error: Failed to remove existing pod 'documenso-pod'\n"
                exit 1
            fi
        fi
        
        # Create pod with extracted configuration
        podman pod create --name documenso-pod $PUBLISH_PORTS
        printf "Created pod 'documenso-pod' with ports: %s\n" "$PUBLISH_PORTS"
    else
        printf "Warning: Pod file %s not found, creating basic pod\n" "$POD_FILE"
        # Remove existing pod if it exists
        if podman pod exists documenso-pod; then
            printf "Cleaning up existing pod 'documenso-pod'...\n"
            # Force stop and remove all containers in the pod first
            podman pod stop documenso-pod 2>/dev/null || true
            podman ps -a --pod --filter pod=documenso-pod --format "{{.ID}}" | xargs -r podman rm -f 2>/dev/null || true
            # Now remove the pod
            podman pod rm -f documenso-pod 2>/dev/null || true
            # Verify pod is gone
            if podman pod exists documenso-pod; then
                printf "Error: Failed to remove existing pod 'documenso-pod'\n"
                exit 1
            fi
        fi
        podman pod create --name documenso-pod --publish 8084:3000
    fi
else
    printf "Podman %s supports .pod Quadlets - systemd will handle pod creation...\n" "$PODMAN_VERSION"
fi

# Create Quadlet files for systemd integration
printf "Creating Quadlet files...\n"
mkdir -p "${HOME}/.config/containers/systemd"
chmod 755 "${HOME}/.config/containers/systemd"

# Copy and configure pod quadlet
cp "${DOCUMENSO_DIR}/documenso.pod" "${HOME}/.config/containers/systemd/documenso.pod"

# Copy and configure Documenso container quadlet
cp "${DOCUMENSO_DIR}/documenso.container" "${HOME}/.config/containers/systemd/documenso.container"
sed -i "s|ENV_FILE_PLACEHOLDER|${DOCUMENSO_DIR}/documenso.env|g" "${HOME}/.config/containers/systemd/documenso.container"
sed -i "s|CERT_VOLUME_PLACEHOLDER|${DOCUMENSO_VOLUMES}/cert.p12:/opt/documenso/cert.p12:ro|g" "${HOME}/.config/containers/systemd/documenso.container"

# Set proper permissions for Quadlet files (systemd generators need to read them)
chmod 644 "${HOME}/.config/containers/systemd"/*.pod
chmod 644 "${HOME}/.config/containers/systemd"/*.container

# Reload systemd to recognize new quadlets
systemctl --user daemon-reload

# Quadlets are created - systemd will manage them
printf "Quadlet files created successfully.\n"

# Start Documenso services (Quadlet-generated services can't be enabled)
printf "Starting Documenso services...\n"
systemctl --user start documenso.service

printf "\n=== Documenso Setup Complete ===\n"
printf "Documenso services have been started.\n"
printf "Access Documenso at: http://localhost:8084\n"
printf "\n=== IMPORTANT SETUP NOTES ===\n"
printf "1. Documenso requires a PostgreSQL database connection\n"
printf "2. Update database settings in %s/documenso.env\n" "$DOCUMENSO_DIR"
printf "3. Configure SMTP settings for email functionality\n"
printf "4. Replace the test certificate with a proper signing certificate\n"
printf "5. Update NEXTAUTH_SECRET and encryption keys for security\n"