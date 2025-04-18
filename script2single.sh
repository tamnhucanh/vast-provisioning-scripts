#!/bin/bash
set -eo pipefail

# Set CivitAI API token from environment variable
export CIVITAI_TOKEN="${CIVITAI_TOKEN}"

# Validate token presence
if [ -z "$CIVITAI_TOKEN" ]; then
  echo "ERROR: CivitAI token not found! Set CIVITAI_TOKEN in Vast.ai template."
  exit 1
fi

# Base paths
FORGE_PATH="/workspace/stable-diffusion-webui-forge"
MODEL_DIR="$FORGE_PATH/models/Stable-diffusion"
LORA_DIR="$FORGE_PATH/models/Lora"

# Function to sanitize filenames
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]._-'
}

# Enhanced function to download CivitAI assets with robust metadata handling
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2
  
  # Create target directory
  mkdir -p "$target_dir" || return 1
  
  # Get model metadata with explicit API call and error checking
  echo "Fetching metadata for model version $model_version_id..."
  
  local api_response
  local api_status
  api_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
    "https://civitai.com/api/v1/model-versions/$model_version_id")
  
  api_status=${api_response: -3}
  local metadata=${api_response:0:${#api_response}-3}
  
  if [[ $api_status != "200" ]]; then
    echo "ERROR: Failed to get metadata for model $model_version_id (HTTP $api_status)"
    echo "API Response: $metadata"
    return 1
  fi
  
  # Validate JSON response
  if ! echo "$metadata" | jq . > /dev/null 2>&1; then
    echo "ERROR: Invalid JSON response for model $model_version_id"
    return 1
  fi
  
  # Extract model info with explicit error handling
  local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
  local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
  local model_type=$(echo "$metadata" | jq -r '.model.type // "unknown"')
  
  echo "Model info: '$model_name' version '$version_name' (type: $model_type)"
  
  if [[ "$model_name" == "null" || "$model_name" == "unknown" ]]; then
    echo "ERROR: Could not determine model name for $model_version_id"
    return 1
  fi
  
  # Extract file info
  local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .name')
  local download_url=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .downloadUrl')
  local preview_image=$(echo "$metadata" | jq -r '.images[0].url // ""')
  
  # Sanitize names
  local safe_model_name=$(sanitize "$model_name")
  local safe_version_name=$(sanitize "$version_name")
  local base_filename="${safe_model_name}_${safe_version_name}"
  
  echo "Using filename base: $base_filename"
  
  # Save raw JSON metadata
  echo "$metadata" > "$target_dir/${base_filename}.json"
  
  # Download model file
  echo "Downloading model: $base_filename"
  curl -fL -H "Authorization: Bearer $CIVITAI_TOKEN" \
    -o "$target_dir/${base_filename}.${primary_file##*.}" \
    "$download_url" || {
      echo "ERROR: Failed to download model file for $model_version_id"
      return 1
    }
  
  # Save description
  local description_html=$(echo "$metadata" | jq -r '.description // ""')
  echo "$description_html" > "$target_dir/${base_filename}.html"
  
  # Download preview image
  if [[ -n "$preview_image" && "$preview_image" != "null" ]]; then
    curl -fL -o "$target_dir/${base_filename}.preview.png" \
      "$preview_image" || echo "Warning: Failed to download preview image"
  else
    echo "Warning: No preview image available for $model_version_id"
  fi
  
  echo "Successfully processed model $model_version_id: $model_name ($version_name)"
  return 0
}

# Install extensions with error resilience
install_extension() {
  local repo_url=$1
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$FORGE_PATH/extensions/$repo_name"
  
  if [ ! -d "$target_dir" ]; then
    echo "Installing extension: $repo_name"
    git clone "$repo_url" "$target_dir" || echo "Warning: Failed to clone $repo_name"
  else
    echo "Extension already installed: $repo_name"
  fi
}

# Function to check if a model is installed
check_model_installed() {
  local model_version_id=$1
  local target_dir=$2
  local max_retries=3
  local retry_count=0
  local success=false

  while [ $retry_count -lt $max_retries ]; do
    # Fetch metadata to get expected filename
    local api_response
    local api_status
    api_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
      "https://civitai.com/api/v1/model-versions/$model_version_id")
    
    api_status=${api_response: -3}
    local metadata=${api_response:0:${#api_response}-3}
    
    if [[ $api_status != "200" ]]; then
      echo "ERROR: Failed to get metadata for model $model_version_id (HTTP $api_status)"
      retry_count=$((retry_count + 1))
      sleep 5
      continue
    fi
    
    local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
    local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
    local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .name')
    
    if [[ "$model_name" == "null" || "$model_name" == "unknown" ]]; then
      echo "ERROR: Could not determine model name for $model_version_id"
      retry_count=$((retry_count + 1))
      sleep 5
      continue
    fi
    
    local safe_model_name=$(sanitize "$model_name")
    local safe_version_name=$(sanitize "$version_name")
    local base_filename="${safe_model_name}_${safe_version_name}"
    local expected_file="$target_dir/${base_filename}.${primary_file##*.}"
    
    # Check if the model file exists
    if [ -f "$expected_file" ]; then
      echo "Model $model_version_id is installed: $expected_file"
      success=true
      break
    else
      echo "Model $model_version_id not found, retrying installation (Attempt $((retry_count + 1))/$max_retries)"
      download_civit_model "$model_version_id" "$target_dir"
      retry_count=$((retry_count + 1))
      sleep 5
    fi
  done

  if [ "$success" = false ]; then
    echo "ERROR: Failed to install model $model_version_id after $max_retries attempts"
    exit 1
  fi
}

# -------------------- Main Execution -------------------- #

echo "Starting provisioning script for Forge UI customization..."

# Install original extensions
install_extension "https://github.com/Mikubill/sd-webui-controlnet.git"
install_extension "https://github.com/camenduru/sd-webui-additional-networks.git"
install_extension "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git"

# Install custom extensions
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git"
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git"
install_extension "https://github.com/Bing-su/adetailer.git"
install_extension "https://github.com/BlafKing/sd-civitai-browser-plus.git"

# ControlNet models setup
mkdir -p "$FORGE_PATH/extensions/sd-webui-controlnet/models"
cd "$FORGE_PATH/extensions/sd-webui-controlnet/models"
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth

# VAE installation
mkdir -p "$FORGE_PATH/models/VAE"
cd "$FORGE_PATH/models/VAE"
wget -nc https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors

# Download base models - NO HARDCODED NAMES, all from API
echo "=== Downloading base models ==="
download_civit_model 1166878 "$MODEL_DIR"
download_civit_model 1612720 "$MODEL_DIR"
download_civit_model 1111838 "$MODEL_DIR"

# Download LoRAs - NO HARDCODED NAMES, all from API
echo "=== Downloading LoRAs ==="
download_civit_model 1568786 "$LORA_DIR"
download_civit_model 1074877 "$LORA_DIR"
download_civit_model 1486082 "$LORA_DIR"
download_civit_model 1360425 "$LORA_DIR"
download_civit_model 1470544 "$LORA_DIR"
download_civit_model 1674551 "$LORA_DIR"
download_civit_model 999582 "$LORA_DIR"
download_civit_model 1364444 "$LORA_DIR"
download_civit_model 1458421 "$LORA_DIR"

# Verify all models and LoRAs are installed
echo "=== Verifying model installations ==="
for model_id in 1166878 1612720 1111838; do
  check_model_installed "$model_id" "$MODEL_DIR"
done

echo "=== Verifying LoRA installations ==="
for lora_id in 1568786 1074877 1486082 1360425 1470544 1674551 999582 1364444 1458421; do
  check_model_installed "$lora_id" "$LORA_DIR"
done

echo "Provisioning completed successfully! All models and LoRAs verified in $MODEL_DIR and $LORA_DIR"
